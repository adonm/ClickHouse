#include <Storages/MergeTree/Streaming/MergeTreeCommitOrderSequentialSource.h>
#include <Storages/MergeTree/Streaming/PartitionsClassification.h>
#include <Storages/MergeTree/Streaming/ReadingPlan/StampPartitionCursors.h>
#include <Storages/MergeTree/Streaming/ReadingPlan/StampPartitionWatermarks.h>
#include <Storages/MergeTree/MergeTreeVirtualColumns.h>
#include <Storages/MergeTree/MergeTreeData.h>

#include <Parsers/IAST.h>

#include <Interpreters/Context.h>

#include <QueryPipeline/QueryPipeline.h>
#include <QueryPipeline/printPipeline.h>

#include <IO/WriteBufferFromString.h>

#include <Processors/IProcessor.h>
#include <Processors/Port.h>
#include <Processors/Streaming/Markers.h>

#include <Core/UUID.h>
#include <Core/Block.h>
#include <Core/Streaming/Settings.h>
#include <Core/Streaming/StreamingVirtualColumns.h>

#include <Common/ZooKeeper/ZooKeeperCommon.h>
#include <Common/Exception.h>
#include <Common/logger_useful.h>
#include <Common/Epoll.h>

#include <base/defines.h>
#include <sys/epoll.h>

#include <algorithm>
#include <memory>

namespace DB
{

namespace
{

std::string explainPipeline(const Pipe & pipe)
{
    WriteBufferFromOwnString buffer;
    printPipeline(pipe.getProcessors(), buffer);
    return buffer.str();
}

ContextPtr makeStreamingContext(ContextPtr context_)
{
    auto copy = Context::createCopy(context_);
    copy->makeQueryContext();
    copy->setQueryMetadataCache(nullptr);
    return copy;
}

SelectQueryInfo makeStreamingSelectQueryInfo(SelectQueryInfo info)
{
    info.table_expression_modifiers = std::nullopt;

    info.query_tree.reset();
    info.table_expression.reset();
    info.planner_context.reset();

    info.prewhere_info.reset();
    info.filter_actions_dag.reset();

    info.order_optimizer.reset();
    info.input_order_info.reset();

    info.trivial_limit = 0;
    info.optimize_trivial_count = false;

    info.has_window = false;
    info.has_order_by = false;
    info.need_aggregate = false;
    info.has_aggregates = false;

    return info;
}

PrewhereInfoPtr makeStreamingPrewhereInfo(PrewhereInfoPtr info, const StreamSettings & stream_settings)
{
    if (!info)
        return nullptr;

    auto patched_info = std::make_shared<PrewhereInfo>(info->clone());

    /// These columns are needed for cursor calculation.
    patched_info->prewhere_actions.tryRestoreColumn(PartitionIdColumn::name);
    patched_info->prewhere_actions.tryRestoreColumn(BlockNumberColumn::name);
    patched_info->prewhere_actions.tryRestoreColumn(BlockOffsetColumn::name);

    /// These columns are needed for watermark calculation.
    if (stream_settings.watermark)
    {
        patched_info->prewhere_actions.tryRestoreColumn(stream_settings.watermark->column);

        IdentifierNameSet identifiers;
        stream_settings.watermark->expression->collectIdentifierNames(identifiers);
        for (const auto & identifier : identifiers)
            patched_info->prewhere_actions.tryRestoreColumn(identifier);
    }

    return patched_info;
}

Names filterStreamingVirtualColumns(Names columns)
{
    if (auto it = std::find(columns.begin(), columns.end(), TimeAttributeColumn::name); it != columns.end())
        columns.erase(it);

    if (auto it = std::find(columns.begin(), columns.end(), WatermarkColumn::name); it != columns.end())
        columns.erase(it);

    return columns;
}

}

MergeTreeCommitOrderSequentialSource::MergeTreeCommitOrderSequentialSource(
    SharedHeader header_,
    const MergeTreeData & storage_,
    const SelectQueryInfo & query_info_,
    ContextPtr context_,
    Names user_requested_columns_,
    size_t requested_num_streams_,
    UInt64 max_block_size_,
    MergeTreeBoundsSubscriptionPtr subscription_)
    : IProcessor({}, {Block(*header_)})
    , header(std::move(header_))
    , subscription(std::move(subscription_))
    , stream_settings(*query_info_.table_expression_modifiers->getStreamSettings())
    , reading_context{
          .storage = storage_,
          .query_info = makeStreamingSelectQueryInfo(query_info_),
          .prewhere_info = makeStreamingPrewhereInfo(query_info_.prewhere_info, stream_settings),
          .stream_settings = stream_settings,
          .context = makeStreamingContext(std::move(context_)),
          .user_requested_columns = filterStreamingVirtualColumns(std::move(user_requested_columns_)),
          .requested_num_streams = requested_num_streams_,
          .max_block_size = max_block_size_,
          .output_header = header}
    , log(getLogger(fmt::format("MergeTreeCommitOrderSequentialSource::{}", UUIDHelpers::generateV4())))
    , read_state(stream_settings)
{
}

IProcessor::Status MergeTreeCommitOrderSequentialSource::handleRunningPipeline()
{
    auto & output = outputs.front();
    auto & input = inputs.front();

    if (!output.canPush())
        return Status::PortFull;

    if (!input.hasData())
    {
        input.setNeeded();
        return Status::NeedData;
    }

    auto chunk = input.pull(/*set_not_needed=*/true);

    if (!input.isFinished())
        input.setNeeded();

    if (auto global_watermark = chunk.getChunkInfos().get<WatermarkMarker>())
        read_state.updateGlobalWatermark(global_watermark->watermark);

    if (auto partition_cursor = chunk.getChunkInfos().extract<PartitionCursorInfo>())
        read_state.updatePartitionCursor(partition_cursor->partition_id, partition_cursor->cursor);

    if (auto partition_marker = chunk.getChunkInfos().extract<PartitionWatermarkInfo>())
    {
        read_state.updatePartitionWatermark(partition_marker->partition_id, std::move(partition_marker->watermark));

        /// The dropped chunk was the last one - the sub-pipeline is exhausted.
        if (input.isFinished())
            return Status::Finished;

        return Status::NeedData;
    }

    output.push(std::move(chunk));
    return Status::PortFull;
}

IProcessor::Status MergeTreeCommitOrderSequentialSource::handleShutdown()
{
    auto & output = outputs.front();
    chassert(output.isFinished());

    if (inputs.empty() || !inputs.front().isConnected())
        return Status::Finished;

    auto & input = inputs.front();
    input.close();

    return Status::Finished;
}

IProcessor::Status MergeTreeCommitOrderSequentialSource::handleReconfiguration(const ClassifiedPartitions & partitions)
{
    auto & output = outputs.front();

    if (output.isFinished())
        return Status::Finished;

    if (pending_round.has_value())
        return Status::UpdatePipeline;

    if (subscription->isDisabled())
    {
        output.finish();
        return Status::Finished;
    }

    if (read_state.hasWork(partitions))
        return Status::Ready;

    if (current_round.has_value())
        return Status::UpdatePipeline;

    return Status::Async;
}

IProcessor::Status MergeTreeCommitOrderSequentialSource::handleBoundedReconfiguration(const ClassifiedPartitions & partitions)
{
    const auto result = handleReconfiguration(partitions);

    // Finish after the first completed read round, or once the first enrichment shows nothing (more) to read.
    if (subscription->wasSubscriptionUpdated() && (finished_rounds > 0 || result == Status::Async))
    {
        outputs.front().finish();
        return Status::Finished;
    }

    return result;
}

bool MergeTreeCommitOrderSequentialSource::needToEmitGlobalIdle(const ClassifiedPartitions & partitions)
{
    if (!stream_settings.watermark)
        return false;

    /// The idle marker must not overtake the watermark extension emitted by the last idle-triggered rebuild.
    if (read_state.hasWork(partitions) || pending_round.has_value())
        return false;

    const bool has_partitions = !partitions.changed_partitions.empty() || !partitions.unchanged_partitions.empty() || !partitions.idle_partitions.empty();
    const bool all_non_idle_empty = partitions.changed_partitions.empty() && partitions.unchanged_partitions.empty();
    const bool source_idle = has_partitions ? all_non_idle_empty : subscription->wasSubscriptionUpdated();

    return !read_state.isSourceMarkedIdle() && source_idle;
}

IProcessor::Status MergeTreeCommitOrderSequentialSource::handleEmitGlobalIdle()
{
    auto & output = outputs.front();

    if (!output.canPush())
        return Status::PortFull;

    LOG_DEBUG(log, "Source is idle - emitting an idle marker");
    output.push(IdleMarker::create(*header));
    read_state.markSourceIdle();
    return Status::PortFull;
}

IProcessor::Status MergeTreeCommitOrderSequentialSource::prepare()
{
    subscription->drain();

    const bool is_upstream_finished = outputs.front().isFinished();
    if (is_upstream_finished)
        return handleShutdown();

    const bool has_running_sub_pipeline = !inputs.empty() && inputs.front().isConnected() && !inputs.front().isFinished();
    if (has_running_sub_pipeline)
        if (auto sub_pipeline_status = handleRunningPipeline(); sub_pipeline_status != Status::Finished)
            return sub_pipeline_status;

    const bool has_unfinalized_pipeline = !pending_round.has_value() && read_state.readRoundInProgress();
    if (has_unfinalized_pipeline)
    {
        read_state.finalizeReadRound();
        finished_rounds += 1;
        LOG_TEST(log, "Finished read round #{}", finished_rounds);
    }

    const auto safe_block_numbers = subscription->snapshot();
    const auto classification = classifyPartitions(read_state, safe_block_numbers, stream_settings);
    read_state.updatePartitionSet(classification);

    const bool need_mark_source_idle = needToEmitGlobalIdle(classification);
    if (need_mark_source_idle)
        return handleEmitGlobalIdle();

    const bool is_bounded_subscription = !stream_settings.subscribe_for_updates;
    if (is_bounded_subscription)
        return handleBoundedReconfiguration(classification);

    return handleReconfiguration(classification);
}

void MergeTreeCommitOrderSequentialSource::work()
{
    auto component_guard = Coordination::setCurrentComponent("MergeTreeCommitOrderSequentialSource::work");

    chassert(!pending_round.has_value());

    if (subscription->isDisabled())
        return;

    const auto safe_block_numbers = subscription->snapshot();
    const auto classification = classifyPartitions(read_state, safe_block_numbers, stream_settings);

    read_state.updatePartitionSet(classification);
    read_state.startReadRound(classification, safe_block_numbers);

    pending_round = buildReadRoundPipeline(reading_context, read_state, safe_block_numbers);
    if (pending_round.has_value())
        LOG_TEST(log, "Built read round pipeline:\n{}", explainPipeline(pending_round->pipe));
}

std::tuple<int, uint32_t, Int64> MergeTreeCommitOrderSequentialSource::scheduleForEvent()
{
    return {subscription->fd(), EPOLLIN | EPOLLERR, read_state.calculateTimeToNextIdle(stream_settings)};
}

IProcessor::PipelineUpdate MergeTreeCommitOrderSequentialSource::updatePipeline()
{
    chassert(pending_round.has_value() || current_round.has_value());

    PipelineUpdate update;

    /// Tear down the previous read round sub-pipeline.
    if (current_round.has_value())
    {
        chassert(!inputs.empty());
        chassert(inputs.front().isConnected());
        LOG_TEST(log, "Tear down previous read round sub-pipeline");

        auto & input = inputs.front();
        disconnect(input.getOutputPort(), input);

        update.to_remove = current_round->pipe.getProcessors();
        current_round.reset();
    }

    /// Attach the next read round sub-pipeline if one is ready.
    if (pending_round.has_value())
    {
        current_round = std::exchange(pending_round, std::nullopt);
        chassert(current_round->pipe.numOutputPorts() == 1);
        LOG_TEST(log, "Connecting next read round sub-pipeline");

        if (inputs.empty())
            inputs.emplace_back(*header, this);

        for (const auto & processor : current_round->pipe.getProcessors())
            processor->inheritQueryPlanStepFromParent(*this, getQueryPlanStepGroup());

        auto & input = inputs.front();
        connect(*current_round->pipe.getOutputPort(0), input);
        input.reopen();
        input.setNeeded();

        update.to_add = current_round->pipe.getProcessors();
    }

    return update;
}

void MergeTreeCommitOrderSequentialSource::onUpdatePorts()
{
    if (outputs.front().isFinished())
        subscription->disable();
}

void MergeTreeCommitOrderSequentialSource::onCancel() noexcept
{
    /// disable() notifies through the wakeup pipe and may throw (e.g. on fd corruption);
    /// propagating from noexcept would terminate the server.
    try
    {
        subscription->disable();
    }
    catch (...)
    {
        tryLogCurrentException(log);
    }
}

}
