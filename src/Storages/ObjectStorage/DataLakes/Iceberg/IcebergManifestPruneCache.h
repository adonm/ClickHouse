#pragma once
#include "config.h"

#if USE_AVRO

#include <Common/CacheBase.h>
#include <Common/ProfileEvents.h>
#include <Common/CurrentMetrics.h>
#include <Storages/ObjectStorage/DataLakes/Iceberg/ManifestFile.h>

namespace ProfileEvents
{
    extern const Event IcebergManifestPruneCacheHits;
    extern const Event IcebergManifestPruneCacheMisses;
    extern const Event IcebergManifestPruneCacheWeightLost;
}

namespace CurrentMetrics
{
    extern const Metric IcebergManifestPruneCacheBytes;
    extern const Metric IcebergManifestPruneCacheFiles;
}

namespace DB::Iceberg
{

/// Cache for partition-pruning decisions: key = manifest_path + "#" +
/// row_index + "#" + partition_filter_hash + "#" + schema ids, value =
/// ManifestPruneCacheValue (entry==nullptr means PARTITION_PRUNED, non-null
/// means the partition predicate kept this entry). The key deliberately
/// excludes the point-lookup literal so every query sharing a prefix hits
/// after the first one; min-max pruning is re-evaluated per query on the
/// few surviving entries. Manifest path changes on new snapshot, so no TTL
/// is needed - old entries are naturally not hit after a snapshot advances
/// and are evicted via LRU.
struct ManifestPruneCacheValue
{
    // nullptr = pruned (PARTITION_PRUNED or MIN_MAX_INDEX_PRUNED), non-null = kept
    ProcessedManifestFileEntryPtr entry;
    // Valid only when entry==nullptr: which prune reason it was
    int prune_status = 0; // PruningReturnStatus as int to avoid header dependency
    bool is_pruned() const { return !entry; }
};

struct ManifestPruneCacheWeightFunction
{
    size_t operator()(const ManifestPruneCacheValue & v) const
    {
        // Each entry is one pointer + overhead; keep weight 1 per row for simple LRU
        // but account for actual object size when kept.
        return v.entry ? 256 : 64;
    }
};

class ManifestPruneCache : public CacheBase<String, ManifestPruneCacheValue, std::hash<String>, ManifestPruneCacheWeightFunction>
{
public:
    using Base = CacheBase<String, ManifestPruneCacheValue, std::hash<String>, ManifestPruneCacheWeightFunction>;

    ManifestPruneCache(const String & cache_policy, size_t max_size_in_bytes, size_t max_count, double size_ratio)
        : Base(cache_policy, CurrentMetrics::IcebergManifestPruneCacheBytes, CurrentMetrics::IcebergManifestPruneCacheFiles, max_size_in_bytes, max_count, size_ratio)
    {
    }

private:
    void onEntryRemoval(const size_t weight_loss, const MappedPtr & /*mapped_ptr*/) override
    {
        ProfileEvents::increment(ProfileEvents::IcebergManifestPruneCacheWeightLost, weight_loss);
    }
};

using ManifestPruneCachePtr = std::shared_ptr<ManifestPruneCache>;

// Global prune cache accessor for SYSTEM CLEAR
ManifestPruneCachePtr getGlobalPruneCache();
void clearGlobalPruneCache();

}

#endif
