#include <Columns/IColumn.h>
#include <Core/Settings.h>
#include <DataTypes/DataTypeString.h>
#include <DataTypes/DataTypesNumber.h>
#include <Interpreters/Context.h>
#include <Storages/ColumnsDescription.h>
#include <Storages/System/StorageSystemSessionQueryIds.h>
#include <Storages/System/SystemTableSourceRegistry.h>


namespace DB
{

namespace Setting
{
    extern const SettingsUInt64 session_query_ids_history_size;
}

ColumnsDescription StorageSystemSessionQueryIds::getColumnsDescription()
{
    return ColumnsDescription
    {
        {"sequence_number", std::make_shared<DataTypeUInt64>(), "Position of the query within the session, monotonically increasing."},
        {"query_id", std::make_shared<DataTypeString>(), "The query id, can be joined with `system.query_log`."},
    };
}

void StorageSystemSessionQueryIds::fillData(MutableColumns & res_columns, ContextPtr context, const ActionsDAG::Node *, std::vector<UInt8>) const
{
    if (!context->hasSessionContext() || context->getSettingsRef()[Setting::session_query_ids_history_size] == 0)
        return;

    for (const auto & entry : context->getSessionContext()->getSessionQueryIds())
    {
        res_columns[0]->insert(entry.sequence_number);
        res_columns[1]->insert(entry.query_id);
    }
}

void StorageSystemSessionQueryIds::truncate(const ASTPtr &, const StorageMetadataPtr &, ContextPtr context, TableExclusiveLockHolder &)
{
    if (context->hasSessionContext())
        context->getSessionContext()->clearSessionQueryIds();
}

}

/// Register the source file of this system table for `system.documentation`.
namespace DB { REGISTER_SYSTEM_TABLE_SOURCE(StorageSystemSessionQueryIds) }
