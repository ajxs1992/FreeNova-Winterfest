#if defined _postgres_included
	#endinput
#endif
#define _postgres_included

#pragma reqlib postgres

#define TQUERY_CONNECT_FAILED	-2
#define TQUERY_QUERY_FAILED	-1
#define TQUERY_SUCCESS		0

/**
 * Queue a PostgreSQL query (async, non-blocking sockets).
 * Callback:
 *   public Handler(failstate, query, error[], errnum, data[], size, Float:queuetime)
 * `query` is only valid inside that callback.
 */
native PG_ThreadQuery(const handler[], const sql[], const data[] = "", dataSize = 0);
native PG_NumResults(query);
native PG_MoreResults(query);
native PG_NextRow(query);
native PG_ReadInt(query, column);
native PG_ReadString(query, column, output[], len);
native bool:PG_IsReady();
