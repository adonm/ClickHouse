#include <Processors/Streaming/RaiseWatermarksTransform.h>
#include <Processors/Streaming/Markers.h>

#include <algorithm>

namespace DB
{

RaiseWatermarksTransform::RaiseWatermarksTransform(SharedHeader header, Field initial_watermark_)
    : ISimpleTransform(header, header, /*skip_empty_chunks=*/false)
    , watermark(std::move(initial_watermark_))
{
}

void RaiseWatermarksTransform::transform(Chunk & chunk)
{
    if (auto marker = chunk.getChunkInfos().extract<WatermarkMarker>())
    {
        watermark = std::max(watermark, marker->watermark);
        marker->watermark = watermark;
        chunk.getChunkInfos().add(std::move(marker));
    }
}

}
