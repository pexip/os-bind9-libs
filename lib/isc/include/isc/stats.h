/*
 * Copyright (C) Internet Systems Consortium, Inc. ("ISC")
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * See the COPYRIGHT file distributed with this work for additional
 * information regarding copyright ownership.
 */


#ifndef ISC_STATS_H
#define ISC_STATS_H 1

/*! \file isc/stats.h */

#include <inttypes.h>

#include <isc/types.h>

ISC_LANG_BEGINDECLS

/*%<
 * Flag(s) for isc_stats_dump().
 */
#define ISC_STATSDUMP_VERBOSE	0x00000001 /*%< dump 0-value counters */

/*%<
 * Dump callback type.
 */
typedef void (*isc_stats_dumper_t)(isc_statscounter_t, uint64_t, void *);

isc_result_t
isc_stats_create(isc_mem_t *mctx, isc_stats_t **statsp, int ncounters);
/*%<
 * Create a statistics counter structure of general type.  It counts a general
 * set of counters indexed by an ID between 0 and ncounters -1.
 *
 * Requires:
 *\li	'mctx' must be a valid memory context.
 *
 *\li	'statsp' != NULL && '*statsp' == NULL.
 *
 * Returns:
 *\li	ISC_R_SUCCESS	-- all ok
 *
 *\li	anything else	-- failure
 */

void
isc_stats_attach(isc_stats_t *stats, isc_stats_t **statsp);
/*%<
 * Attach to a statistics set.
 *
 * Requires:
 *\li	'stats' is a valid isc_stats_t.
 *
 *\li	'statsp' != NULL && '*statsp' == NULL
 */

void
isc_stats_detach(isc_stats_t **statsp);
/*%<
 * Detaches from the statistics set.
 *
 * Requires:
 *\li	'statsp' != NULL and '*statsp' is a valid isc_stats_t.
 */

int
isc_stats_ncounters(isc_stats_t *stats);
/*%<
 * Returns the number of counters contained in stats.
 *
 * Requires:
 *\li	'stats' is a valid isc_stats_t.
 *
 */

void
isc_stats_increment(isc_stats_t *stats, isc_statscounter_t counter);
/*%<
 * Increment the counter-th counter of stats.
 *
 * Requires:
 *\li	'stats' is a valid isc_stats_t.
 *
 *\li	counter is less than the maximum available ID for the stats specified
 *	on creation.
 */

void
isc_stats_decrement(isc_stats_t *stats, isc_statscounter_t counter);
/*%<
 * Decrement the counter-th counter of stats.
 *
 * Requires:
 *\li	'stats' is a valid isc_stats_t.
 */

void
isc_stats_dump(isc_stats_t *stats, isc_stats_dumper_t dump_fn, void *arg,
	       unsigned int options);
/*%<
 * Dump the current statistics counters in a specified way.  For each counter
 * in stats, dump_fn is called with its current value and the given argument
 * arg.  By default counters that have a value of 0 is skipped; if options has
 * the ISC_STATSDUMP_VERBOSE flag, even such counters are dumped.
 *
 * Requires:
 *\li	'stats' is a valid isc_stats_t.
 */

void
isc_stats_set(isc_stats_t *stats, uint64_t val,
	      isc_statscounter_t counter);
/*%<
 * Set the given counter to the specified value.
 *
 * Requires:
 *\li	'stats' is a valid isc_stats_t.
 */

void
isc_stats_set(isc_stats_t *stats, uint64_t val,
	      isc_statscounter_t counter);
/*%<
 * Set the given counter to the specified value.
 *
 * Requires:
 *\li	'stats' is a valid isc_stats_t.
 */

void isc_stats_update_if_greater(isc_stats_t *stats,
				 isc_statscounter_t counter,
				 uint64_t value);
/*%<
* Atomically assigns 'value' to 'counter' if value > counter.
*
* Requires:
*\li	'stats' is a valid isc_stats_t.
*
*\li	counter is less than the maximum available ID for the stats specified
*	on creation.
*/

uint64_t
isc_stats_get_counter(isc_stats_t *stats, isc_statscounter_t counter);
/*%<
 * Returns value currently stored in counter.
 *
 * Requires:
 *\li	'stats' is a valid isc_stats_t.
 *
 *\li	counter is less than the maximum available ID for the stats specified
 *	on creation.
 */

ISC_LANG_ENDDECLS

#endif /* ISC_STATS_H */
