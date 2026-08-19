#pragma once

#include <Processors/ISimpleTransform.h>

#include <Core/Field.h>

namespace DB
{

/// Aggregates the watermark markers of a stream with a running maximum so the emitted watermarks never regress.
class RaiseWatermarksTransform final : public ISimpleTransform
{
public:
    RaiseWatermarksTransform(SharedHeader header, Field initial_watermark_);

    String getName() const override { return "RaiseWatermarks"; }

protected:
    void transform(Chunk & chunk) override;

private:
    Field watermark;
};

}
