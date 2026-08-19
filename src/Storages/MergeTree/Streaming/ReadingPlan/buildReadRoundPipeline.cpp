#include <Storages/MergeTree/Streaming/ReadingPlan/buildReadRoundPipeline.h>
#include <Storages/MergeTree/Streaming/ReadingPlan/StampPartitionWatermarks.h>
#include <Storages/MergeTree/Streaming/ReadingPlan/StampPartitionCursors.h>
#include <Storages/MergeTree/Streaming/PartitionsClassification.h>
#include <Storages/MergeTree/Streaming/Cursors/CursorUtils.h>
#include <Storages/MergeTree/MergeTreeDataSelectExecutor.h>
#include <Storages/MergeTree/MergeTreeVirtualColumns.h>
#include <Storages/StorageSnapshot.h>

#include <Parsers/IAST.h>

#include <Interpreters/ActionsDAG.h>
#include <Interpreters/Context.h>

#include <IO/WriteBufferFromString.h>

#include <QueryPipeline/QueryPipeline.h>
#include <QueryPipeline/QueryPipelineBuilder.h>
#include <QueryPipeline/printPipeline.h>

#include <Processors/QueryPlan/Streaming/CalculateWatermarksStep.h>
#include <Processors/QueryPlan/Streaming/RaiseWatermarksStep.h>
#include <Processors/QueryPlan/BuildQueryPipelineSettings.h>
#include <Processors/QueryPlan/ExpressionStep.h>
#include <Processors/QueryPlan/FilterStep.h>
#include <Processors/QueryPlan/Optimizations/QueryPlanOptimizationSettings.h>
#include <Processors/QueryPlan/QueryPlan.h>
#include <Processors/QueryPlan/SortingStep.h>
#include <Processors/Sources/SourceFromSingleChunk.h>
#include <Processors/Streaming/Markers.h>

#include <Core/Block.h>
#include <Core/SortDescription.h>
#include <Core/Streaming/StreamingVirtualColumns.h>

#include <Common/logger_useful.h>

#include <algorithm>
#include <memory>

namespace DB
{

namespace
{

SelectQueryInfo makeSelectQueryInfoForPartitionRead(const SelectQueryInfo & initial)
{
    SelectQueryInfo info = initial;

    if (info.row_level_filter)
    {
        info.row_level_filter = std::make_shared<FilterDAGInfo>();
        info.row_level_filter->actions = initial.row_level_filter->actions.clone();
        info.row_level_filter->column_name = initial.row_level_filter->column_name;
        info.row_level_filter->do_remove_column = initial.row_level_filter->do_remove_column;
    }

    return info;
}

Names extendWithAuxiliaryColumns(Names columns, const StreamSettings & stream_settings)
{
    for (const auto & aux_name : {PartitionIdColumn::name, BlockNumberColumn::name, BlockOffsetColumn::name})
        if (!std::ranges::contains(columns, aux_name))
            columns.push_back(aux_name);

    if (stream_settings.watermark)
    {
        if (!std::ranges::contains(columns, stream_settings.watermark->column))
            columns.push_back(stream_settings.watermark->column);

        IdentifierNameSet identifiers;
        stream_settings.watermark->expression->collectIdentifierNames(identifiers);
        for (const auto & identifier : identifiers)
            if (!std::ranges::contains(columns, identifier))
                columns.push_back(identifier);
    }

    return columns;
}

Pipe buildPartitionReadingPipeline(
    const ReadRoundContext & reading_context,
    const ReadState & state,
    const String & partition_id,
    const Int64 & safe_block_number,
    const StorageSnapshotPtr & storage_snapshot,
    const Names & inner_columns,
    const QueryPlanOptimizationSettings & opt_settings,
    QueryPlanResourceHolder & resources)
{
    const auto & stream_settings = reading_context.stream_settings;
    const auto & context = reading_context.context;
    const auto & prewhere_info = reading_context.prewhere_info;
    const auto & output_header = reading_context.output_header;

    auto partition_query_info = makeSelectQueryInfoForPartitionRead(reading_context.query_info);
    auto plan = MergeTreeDataSelectExecutor(reading_context.storage).read(
        inner_columns,
        storage_snapshot,
        partition_query_info,
        context,
        reading_context.max_block_size,
        reading_context.requested_num_streams,
        /*max_block_numbers_to_read=*/nullptr,
        /*enable_parallel_reading=*/false);

    if (!plan || !plan->getRootNode())
        return {};

    /// Add cursor filter to read only the safe round slice.
    auto cursor_filter = buildPartitionFilter(partition_id, state.getPartitionCursor(partition_id), safe_block_number, *plan->getCurrentHeader(), context);
    plan->addStep(std::make_unique<FilterStep>(
        plan->getCurrentHeader(),
        std::move(cursor_filter.actions),
        cursor_filter.column_name,
        cursor_filter.do_remove_column));

    /// Add prewhere built from the outer query analysis.
    if (prewhere_info)
    {
        plan->addStep(std::make_unique<FilterStep>(
            plan->getCurrentHeader(),
            prewhere_info->prewhere_actions.clone(),
            prewhere_info->prewhere_column_name,
            prewhere_info->remove_prewhere_column));
    }

    /// Commit-order sort (_block_number, _block_offset); skipped for unordered streams (ordering holds only between rounds).
    if (!stream_settings.unordered)
    {
        SortDescription sort_desc;
        sort_desc.emplace_back(BlockNumberColumn::name, 1);
        sort_desc.emplace_back(BlockOffsetColumn::name, 1);
        SortingStep::Settings sort_settings(context->getSettingsRef());
        plan->addStep(std::make_unique<SortingStep>(
            plan->getCurrentHeader(),
            std::move(sort_desc),
            /*limit=*/ 0,
            sort_settings,
            /*is_sorting_for_merge_join=*/false));
    }

    /// Add cursor calculation step.
    plan->addStep(std::make_unique<StampPartitionCursorsStep>(plan->getCurrentHeader(), stream_settings.unordered));

    /// Add watermark calculation step.
    if (stream_settings.watermark)
    {
        plan->addStep(std::make_unique<CalculateWatermarksStep>(plan->getCurrentHeader(), stream_settings.watermark, context));
        plan->addStep(std::make_unique<RaiseWatermarksStep>(plan->getCurrentHeader(), state.getPartitionWatermark(partition_id)));
        plan->addStep(std::make_unique<StampPartitionWatermarksStep>(plan->getCurrentHeader(), partition_id));
    }

    /// Add projection to required header.
    auto convert = ActionsDAG::makeConvertingActions(
        plan->getCurrentHeader()->getColumnsWithTypeAndName(),
        output_header->getColumnsWithTypeAndName(),
        ActionsDAG::MatchColumnsMode::Name,
        context);
    plan->addStep(std::make_unique<ExpressionStep>(plan->getCurrentHeader(), std::move(convert)));

    /// Build pipeline.
    plan->optimize(opt_settings);
    auto builder = plan->buildQueryPipeline(opt_settings, BuildQueryPipelineSettings(context), /*do_optimize=*/false);
    return QueryPipelineBuilder::getPipe(std::move(*builder), resources);
}

Pipe makePlaceholderPipe(const SharedHeader & output_header, Chunk chunk)
{
    return Pipe(std::make_shared<SourceFromSingleChunk>(output_header, std::move(chunk)));
}

}

std::optional<ReadRoundPipeline> buildReadRoundPipeline(
    const ReadRoundContext & reading_context,
    const ReadState & state,
    const std::map<String, Int64> & safe_block_numbers)
{
    const auto & stream_settings = reading_context.stream_settings;
    const auto & context = reading_context.context;
    const auto & output_header = reading_context.output_header;

    /// Fresh storage snapshot reused by every per-partition subplan in this iteration.
    const auto metadata = reading_context.storage.getInMemoryMetadataPtr(context, /*bypass_metadata_cache=*/true);
    const auto storage_snapshot = reading_context.storage.getStorageSnapshot(metadata, context);
    const auto columns_to_read = extendWithAuxiliaryColumns(reading_context.user_requested_columns, stream_settings);
    const auto classification = classifyPartitions(state, safe_block_numbers, stream_settings);
    const QueryPlanOptimizationSettings opt_settings(context);

    ReadRoundPipeline result;
    Pipes pipes;

    for (const auto & partition_id : classification.changed_partitions)
    {
        auto pipe = buildPartitionReadingPipeline(
            reading_context,
            state,
            partition_id,
            safe_block_numbers.at(partition_id),
            storage_snapshot,
            columns_to_read,
            opt_settings,
            result.resources);

        if (!pipe.empty())
            pipes.emplace_back(std::move(pipe));
    }

    if (stream_settings.watermark)
    {
        for (const auto & partition_id : classification.unchanged_partitions)
            pipes.emplace_back(makePlaceholderPipe(output_header, WatermarkMarker::create(*output_header, state.getPartitionWatermark(partition_id))));
    }

    if (pipes.empty())
        return std::nullopt;

    result.pipe = Pipe::unitePipes(std::move(pipes));

    if (stream_settings.watermark)
        result.pipe.calibrateWatermarks(1);
    else
        result.pipe.resize(1);

    return result;
}

}
