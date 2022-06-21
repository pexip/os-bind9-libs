#!/bin/sh
#
# Copyright (C) Internet Systems Consortium, Inc. ("ISC")
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# See the COPYRIGHT file distributed with this work for additional
# information regarding copyright ownership.

SYSTEMTESTTOP=..
. $SYSTEMTESTTOP/conf.sh

status=0
n=0

DIGOPTS="+tcp +noadd +nosea +nostat +nocmd +dnssec -p ${PORT}"
RNDCCMD="$RNDC -c $SYSTEMTESTTOP/common/rndc.conf -p ${CONTROLPORT} -s"

wait_for_log () {
	msg=$1
	file=$2
	for i in 1 2 3 4 5 6 7 8 9 10; do
		nextpart "$file" | grep "$msg" > /dev/null && return
		sleep 1
	done
	echo_i "exceeded time limit waiting for '$msg' in $file"
	ret=1
}

# convert private-type records to readable form
showprivate () {
    echo "-- $@ --"
    $DIG $DIGOPTS +nodnssec +short @$2 -t type65534 $1 | cut -f3 -d' ' |
        while read record; do
            $PERL -e 'my $rdata = pack("H*", @ARGV[0]);
                die "invalid record" unless length($rdata) == 5;
                my ($alg, $key, $remove, $complete) = unpack("CnCC", $rdata);
                my $action = "signing";
                $action = "removing" if $remove;
                my $state = " (incomplete)";
                $state = " (complete)" if $complete;
                print ("$action: alg: $alg, key: $key$state\n");' $record
        done
}

# check that signing records are marked as complete
checkprivate () {
    _ret=0
    expected="${3:-0}"
    x=`showprivate "$@"`
    echo $x | grep incomplete > /dev/null && _ret=1

    if [ $_ret = $expected ]; then
        return 0
    fi

    echo "$x"
    echo_i "failed"
    return 1
}

# wait until notifies for zone $1 are sent by server $2. This is an indication
# that the zone is signed with the active keys, and the changes have been
# committed.
wait_for_notifies () {
	wait_for_log "zone ${1}/IN: sending notifies" "${2}/named.run" || return 1
}

freq() {
	_file=$1
	# remove first and last line that has incomplete set and skews the distribution
	awk '$4 == "RRSIG" {print substr($9,1,8)}' < "$_file" | sort | uniq -c | sed '1d;$d'
}
# Check the signatures expiration times.  First check how many signatures
# there are in total ($rrsigs).  Then see what the distribution of signature
# expiration times is ($expiretimes).  Ignore the time part for a better
# modelled distribution.
checkjitter () {
	_file=$1
	_ret=0

	if ! command -v bc >/dev/null 2>&1; then
		echo_i "skip: bc not available"
		return 0
	fi

	freq "$_file" | cat_i
	_expiretimes=`freq "$_file" | awk '{print $1}'`

	_count=0
	# Check if we have at least 5 days
	# This number has been tuned for `sig-validity-interval 10 2`, as
	# 1. 1. signature expiration dates should be spread out across at most 8 (10-2) days
	# 2. we remove first and last day to remove frequency outlier, we are left with 6 (8-2) days
	# 3. we subtract one more day to allow test pass on day boundaries, etc. leaving us with 5 (6-1) days
	for _num in $_expiretimes
	do
		_count=$((_count+1))
	done
	if [ "$_count" -lt 5 ]; then
		echo_i "error: not enough categories"
		return 1
	fi

	# Calculate mean
	_total=0
	for _num in $_expiretimes
	do
		_total=$((_total+_num))
	done
	_mean=$(($_total / $_count))

	# Calculate stddev
	_stddev=0
	for _num in $_expiretimes
	do
		_stddev=`echo "$_stddev + (($_num - $_mean) * ($_num - $_mean))" | bc`
	done
	_stddev=`echo "sqrt($_stddev/$_count)" | bc`

	# We expect the number of signatures not to exceed the mean +- 3 * stddev.
	_limit=$((_stddev*3))
	_low=$((_mean-_limit))
	_high=$((_mean+_limit))
	# Find outliers.
	echo_i "checking whether all frequencies fall into <$_low;$_high> range"
	for _num in $_expiretimes
	do
		if [ $_num -gt $_high ]; then
			echo_i "error: too many RRSIG records ($_num) in expiration bucket"
			_ret=1
		fi
		if [ $_num -lt $_low ]; then
			echo_i "error: too few RRSIG records ($_num) in expiration bucket"
			_ret=1
		fi
	done

	return $_ret
}

#
#  The NSEC record at the apex of the zone and its RRSIG records are
#  added as part of the last step in signing a zone.  We wait for the
#  NSEC records to appear before proceeding with a counter to prevent
#  infinite loops if there is a error.
#
echo_i "waiting for autosign changes to take effect"
i=0
while [ $i -lt 30 ]
do
	ret=0
	#
	# Wait for the root DNSKEY RRset to be fully signed.
	#
	$DIG $DIGOPTS . @10.53.0.1 dnskey > dig.out.ns1.test$n || ret=1
	grep "ANSWER: 10," dig.out.ns1.test$n > /dev/null || ret=1
	for z in .
	do
		$DIG $DIGOPTS $z @10.53.0.1 nsec > dig.out.ns1.test$n || ret=1
		grep "NS SOA" dig.out.ns1.test$n > /dev/null || ret=1
	done
	for z in bar. example. private.secure.example.
	do
		$DIG $DIGOPTS $z @10.53.0.2 nsec > dig.out.ns2.test$n || ret=1
		grep "NS SOA" dig.out.ns2.test$n > /dev/null || ret=1
	done
	for z in bar. example. inacksk2.example. inacksk3.example \
		 inaczsk2.example. inaczsk3.example
	do
		$DIG $DIGOPTS $z @10.53.0.3 nsec > dig.out.ns3.test$n || ret=1
		grep "NS SOA" dig.out.ns3.test$n > /dev/null || ret=1
	done
	i=`expr $i + 1`
	if [ $ret = 0 ]; then break; fi
	echo_i "waiting ... ($i)"
	sleep 2
done
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "done"; fi
status=`expr $status + $ret`

echo_i "Initial counts of RRSIG expiry fields values for auto signed zones"
for z in .
do
	echo_i zone $z
	$DIG $DIGOPTS $z @10.53.0.1 axfr | awk '$4 == "RRSIG" {print $9}' | sort | uniq -c | cat_i
done
for z in bar. example. private.secure.example.
do
	echo_i zone $z
	$DIG $DIGOPTS $z @10.53.0.2 axfr | awk '$4 == "RRSIG" {print $9}' | sort | uniq -c | cat_i
done
for z in inacksk2.example. inacksk3.example inaczsk2.example. inaczsk3.example
do
	echo_i zone $z
	$DIG $DIGOPTS $z @10.53.0.3 axfr | awk '$4 == "RRSIG" {print $9}' | sort | uniq -c | cat_i
done

# Set logfile offset for wait_for_log usage.
nextpartreset ns3/named.run

#
# Check that DNSKEY is initially signed with a KSK and not a ZSK.
#
echo_i "check that zone with active and inactive KSK and active ZSK is properly"
echo_ic "resigned after the active KSK is deleted - stage 1: Verify that DNSKEY"
echo_ic "is initially signed with a KSK and not a ZSK. ($n)"
ret=0

$DIG $DIGOPTS @10.53.0.3 axfr inacksk3.example > dig.out.ns3.test$n

zskid=`awk '$4 == "DNSKEY" && $5 == 256 { print }' dig.out.ns3.test$n |
       $DSFROMKEY -A -2 -f - inacksk3.example | awk '{ print $4}'`
grep "DNSKEY 7 2 " dig.out.ns3.test$n > /dev/null || ret=1

pattern="DNSKEY 7 2 [0-9]* [0-9]* [0-9]* ${zskid} "
grep "${pattern}" dig.out.ns3.test$n > /dev/null && ret=1

count=`awk 'BEGIN { count = 0 }
	    $4 == "RRSIG" && $5 == "DNSKEY" { count++ }
	    END {print count}' dig.out.ns3.test$n`
test $count -eq 1 || ret=1

count=`awk 'BEGIN { count = 0 }
       $4 == "DNSKEY" { count++ }
       END {print count}' dig.out.ns3.test$n`
test $count -eq 3 || ret=1

awk='$4 == "RRSIG" && $5 == "DNSKEY" { printf "%05u\n", $11 }'
id=`awk "${awk}" dig.out.ns3.test$n`

$SETTIME -D now+5 ns3/Kinacksk3.example.+007+${id} > settime.out.test$n || ret=1
($RNDCCMD 10.53.0.3 loadkeys inacksk3.example 2>&1 | sed 's/^/ns3 /' | cat_i) || ret=1

n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

#
# Check that zone is initially signed with a ZSK and not a KSK.
#
echo_i "check that zone with active and inactive ZSK and active KSK is properly"
echo_ic "resigned after the active ZSK is deleted - stage 1: Verify that zone"
echo_ic "is initially signed with a ZSK and not a KSK. ($n)"
ret=0
$DIG $DIGOPTS @10.53.0.3 axfr inaczsk3.example > dig.out.ns3.test$n
kskid=`awk '$4 == "DNSKEY" && $5 == 257 { print }' dig.out.ns3.test$n |
       $DSFROMKEY -2 -f - inaczsk3.example | awk '{ print $4}' `
grep "CNAME 7 3 " dig.out.ns3.test$n > /dev/null || ret=1
grep "CNAME 7 3 [0-9]* [0-9]* [0-9]* ${kskid} " dig.out.ns3.test$n > /dev/null && ret=1
count=`awk 'BEGIN { count = 0 }
	    $4 == "RRSIG" && $5 == "CNAME" { count++ }
	    END {print count}' dig.out.ns3.test$n`
test $count -eq 1 || ret=1
count=`awk 'BEGIN { count = 0 }
       $4 == "DNSKEY" { count++ }
       END {print count}' dig.out.ns3.test$n`
test $count -eq 3 || ret=1
id=`awk '$4 == "RRSIG" && $5 == "CNAME" { printf "%05u\n", $11 }' dig.out.ns3.test$n`
$SETTIME -D now+5 ns3/Kinaczsk3.example.+007+${id} > settime.out.test$n || ret=1
($RNDCCMD 10.53.0.3 loadkeys inaczsk3.example 2>&1 | sed 's/^/ns3 /' | cat_i) || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking NSEC->NSEC3 conversion prerequisites ($n)"
ret=0
# these commands should result in an empty file:
$DIG $DIGOPTS +noall +answer nsec3.example. nsec3param @10.53.0.3 > dig.out.ns3.1.test$n || ret=1
grep "NSEC3PARAM" dig.out.ns3.1.test$n > /dev/null && ret=1
$DIG $DIGOPTS +noall +answer autonsec3.example. nsec3param @10.53.0.3 > dig.out.ns3.2.test$n || ret=1
grep "NSEC3PARAM" dig.out.ns3.2.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking NSEC3->NSEC conversion prerequisites ($n)"
ret=0
$DIG $DIGOPTS +noall +answer nsec3-to-nsec.example. nsec3param @10.53.0.3 > dig.out.ns3.test$n || ret=1
grep "NSEC3PARAM" dig.out.ns3.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "converting zones from nsec to nsec3"
$NSUPDATE > /dev/null 2>&1 <<END	|| status=1
server 10.53.0.3 ${PORT}
zone nsec3.nsec3.example.
update add nsec3.nsec3.example. 3600 NSEC3PARAM 1 0 10 BEEF
send
zone optout.nsec3.example.
update add optout.nsec3.example. 3600 NSEC3PARAM 1 1 10 BEEF
send
zone nsec3.example.
update add nsec3.example. 3600 NSEC3PARAM 1 0 10 BEEF
send
zone autonsec3.example.
update add autonsec3.example. 3600 NSEC3PARAM 1 0 20 DEAF
send
zone nsec3.optout.example.
update add nsec3.optout.example. 3600 NSEC3PARAM 1 0 10 BEEF
send
zone optout.optout.example.
update add optout.optout.example. 3600 NSEC3PARAM 1 1 10 BEEF
send
zone optout.example.
update add optout.example. 3600 NSEC3PARAM 1 1 10 BEEF
send
END

# try to convert nsec.example; this should fail due to non-NSEC key
echo_i "preset nsec3param in unsigned zone via nsupdate ($n)"
$NSUPDATE > nsupdate.out 2>&1 <<END
server 10.53.0.3 ${PORT}
zone nsec.example.
update add nsec.example. 3600 NSEC3PARAM 1 0 10 BEEF
send
END

echo_i "checking for nsec3param in unsigned zone ($n)"
ret=0
$DIG $DIGOPTS +noall +answer autonsec3.example. nsec3param @10.53.0.3 > dig.out.ns3.test$n || ret=1
grep "NSEC3PARAM" dig.out.ns3.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking for nsec3param signing record ($n)"
ret=0
$RNDCCMD 10.53.0.3 signing -list autonsec3.example. > signing.out.test$n 2>&1
grep "Pending NSEC3 chain 1 0 20 DEAF" signing.out.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "resetting nsec3param via rndc signing ($n)"
ret=0
$RNDCCMD 10.53.0.3 signing -clear all autonsec3.example. > /dev/null 2>&1
$RNDCCMD 10.53.0.3 signing -nsec3param 1 1 10 beef autonsec3.example. > /dev/null 2>&1
for i in 0 1 2 3 4 5 6 7 8 9; do
	ret=0
	$RNDCCMD 10.53.0.3 signing -list autonsec3.example. > signing.out.test$n 2>&1
	grep "Pending NSEC3 chain 1 1 10 BEEF" signing.out.test$n > /dev/null || ret=1
	num=`grep "Pending " signing.out.test$n | wc -l`
	[ $num -eq 1 ] || ret=1
	[ $ret -eq 0 ] && break
	echo_i "waiting ... ($i)"
	sleep 2
done
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "signing preset nsec3 zone"
zsk=`cat autozsk.key`
ksk=`cat autoksk.key`
$SETTIME -K ns3 -P now -A now $zsk > settime.out.test$n.zsk || ret=1
$SETTIME -K ns3 -P now -A now $ksk > settime.out.test$n.ksk || ret=1
($RNDCCMD 10.53.0.3 loadkeys autonsec3.example. 2>&1 | sed 's/^/ns3 /' | cat_i) || ret=1

echo_i "waiting for changes to take effect"
sleep 3

echo_i "converting zone from nsec3 to nsec"
$NSUPDATE > /dev/null 2>&1 << END	|| status=1
server 10.53.0.3 ${PORT}
zone nsec3-to-nsec.example.
update delete nsec3-to-nsec.example. NSEC3PARAM
send
END

echo_i "waiting for change to take effect"
sleep 3

echo_i "checking that expired RRSIGs from missing key are not deleted ($n)"
ret=0
missing=`keyfile_to_key_id \`cat missingzsk.key\``
$JOURNALPRINT ns3/nozsk.example.db.jnl | \
   awk '{if ($1 == "del" && $5 == "RRSIG" && $12 == id) {exit 1}} END {exit 0}' id=$missing || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that expired RRSIGs from inactive key are not deleted ($n)"
ret=0
inactive=`keyfile_to_key_id \`cat inactivezsk.key\``
$JOURNALPRINT ns3/inaczsk.example.db.jnl | \
   awk '{if ($1 == "del" && $5 == "RRSIG" && $12 == id) {exit 1}} END {exit 0}' id=$inactive || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that non-replaceable RRSIGs are logged only once (missing private key) ($n)"
ret=0
loglines=`grep "Key nozsk.example/NSEC3RSASHA1/$missing .* retaining signatures" ns3/named.run | wc -l`
[ "$loglines" -eq 1 ] || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that non-replaceable RRSIGs are logged only once (inactive private key) ($n)"
ret=0
loglines=`grep "Key inaczsk.example/NSEC3RSASHA1/$inactive .* retaining signatures" ns3/named.run | wc -l`
[ "$loglines" -eq 1 ] || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

# Send rndc sync command to ns1, ns2 and ns3, to force the dynamically
# signed zones to be dumped to their zone files
echo_i "dumping zone files"
($RNDCCMD 10.53.0.1 sync 2>&1 | sed 's/^/ns1 /' | cat_i) || ret=1
($RNDCCMD 10.53.0.2 sync 2>&1 | sed 's/^/ns2 /' | cat_i) || ret=1
($RNDCCMD 10.53.0.3 sync 2>&1 | sed 's/^/ns3 /' | cat_i) || ret=1

now="`TZ=UTC date +%Y%m%d%H%M%S`"
check_expiry() (
	$DIG $DIGOPTS AXFR oldsigs.example @10.53.0.3 > dig.out.test$n
	nearest_expiration="`awk '$4 == "RRSIG" { print $9 }' < dig.out.test$n | sort -n | head -1`"
	if [ "$nearest_expiration" -le "$now" ]; then
		echo_i "failed: $nearest_expiration <= $now"
		return 1
	fi
)

echo_i "checking expired signatures were updated ($n)"
retry 10 check_expiry || ret=1
$DIG $DIGOPTS +noauth a.oldsigs.example. @10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.oldsigs.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

# Check jitter distribution.
echo_i "checking expired signatures were jittered correctly ($n)"
ret=0
$DIG $DIGOPTS axfr oldsigs.example @10.53.0.3 > dig.out.ns3.test$n || ret=1
checkjitter dig.out.ns3.test$n || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking NSEC->NSEC3 conversion succeeded ($n)"
ret=0
$DIG $DIGOPTS nsec3.example. nsec3param @10.53.0.3 > dig.out.ns3.ok.test$n || ret=1
grep "status: NOERROR" dig.out.ns3.ok.test$n > /dev/null || ret=1
$DIG $DIGOPTS +noauth q.nsec3.example. @10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth q.nsec3.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
grep "status: NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking direct NSEC3 autosigning succeeded ($n)"
ret=0
$DIG $DIGOPTS +noall +answer autonsec3.example. nsec3param @10.53.0.3 > dig.out.ns3.ok.test$n || ret=1
[ -s  dig.out.ns3.ok.test$n ] || ret=1
grep "NSEC3PARAM" dig.out.ns3.ok.test$n > /dev/null || ret=1
$DIG $DIGOPTS +noauth q.autonsec3.example. @10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth q.autonsec3.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
grep "status: NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking NSEC->NSEC3 conversion failed with NSEC-only key ($n)"
ret=0
grep "failed: REFUSED" nsupdate.out > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking NSEC3->NSEC conversion succeeded ($n)"
ret=0
# this command should result in an empty file:
$DIG $DIGOPTS +noall +answer nsec3-to-nsec.example. nsec3param @10.53.0.3 > dig.out.ns3.nx.test$n || ret=1
grep "NSEC3PARAM" dig.out.ns3.nx.test$n > /dev/null && ret=1
$DIG $DIGOPTS +noauth q.nsec3-to-nsec.example. @10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth q.nsec3-to-nsec.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
grep "status: NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking NSEC3->NSEC conversion with 'rndc signing -nsec3param none' ($n)"
ret=0
$RNDCCMD 10.53.0.3 signing -nsec3param none autonsec3.example. > /dev/null 2>&1
# this command should result in an empty file:
no_nsec3param() (
 $DIG $DIGOPTS +noall +answer autonsec3.example. nsec3param @10.53.0.3 > dig.out.ns3.nx.test$n || return 1
 grep "NSEC3PARAM" dig.out.ns3.nx.test$n > /dev/null && return 1
 return 0
)
retry_quiet 10 no_nsec3param || ret=1
$DIG $DIGOPTS +noauth q.autonsec3.example. @10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth q.autonsec3.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
grep "status: NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking TTLs of imported DNSKEYs (no default) ($n)"
ret=0
$DIG $DIGOPTS +tcp +noall +answer dnskey ttl1.example. @10.53.0.3 > dig.out.ns3.test$n || ret=1
[ -s dig.out.ns3.test$n ] || ret=1
(awk 'BEGIN {r=0} $2 != 300 {r=1; print "found TTL " $2} END {exit r}' dig.out.ns3.test$n | cat_i) || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking TTLs of imported DNSKEYs (with default) ($n)"
ret=0
$DIG $DIGOPTS +tcp +noall +answer dnskey ttl2.example. @10.53.0.3 > dig.out.ns3.test$n || ret=1
[ -s dig.out.ns3.test$n ] || ret=1
(awk 'BEGIN {r=0} $2 != 60 {r=1; print "found TTL " $2} END {exit r}' dig.out.ns3.test$n | cat_i) || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking TTLs of imported DNSKEYs (mismatched) ($n)"
ret=0
$DIG $DIGOPTS +tcp +noall +answer dnskey ttl3.example. @10.53.0.3 > dig.out.ns3.test$n || ret=1
[ -s dig.out.ns3.test$n ] || ret=1
(awk 'BEGIN {r=0} $2 != 30 {r=1; print "found TTL " $2} END {exit r}' dig.out.ns3.test$n | cat_i) || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking TTLs of imported DNSKEYs (existing RRset) ($n)"
ret=0
$DIG $DIGOPTS +tcp +noall +answer dnskey ttl4.example. @10.53.0.3 > dig.out.ns3.test$n || ret=1
[ -s dig.out.ns3.test$n ] || ret=1
(awk 'BEGIN {r=0} $2 != 30 {r=1; print "found TTL " $2} END {exit r}' dig.out.ns3.test$n | cat_i) || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking positive validation NSEC ($n)"
ret=0
$DIG $DIGOPTS +noauth a.example. @10.53.0.2 a > dig.out.ns2.test$n || ret=1
$DIG $DIGOPTS +noauth a.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns2.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking positive validation NSEC3 ($n)"
ret=0
$DIG $DIGOPTS +noauth a.nsec3.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.nsec3.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking positive validation OPTOUT ($n)"
ret=0
$DIG $DIGOPTS +noauth a.optout.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.optout.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking negative validation NXDOMAIN NSEC ($n)"
ret=0
$DIG $DIGOPTS +noauth q.example. @10.53.0.2 a > dig.out.ns2.test$n || ret=1
$DIG $DIGOPTS +noauth q.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns2.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
grep "status: NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking negative validation NXDOMAIN NSEC3 ($n)"
ret=0
$DIG $DIGOPTS +noauth q.nsec3.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth q.nsec3.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
grep "status: NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking negative validation NXDOMAIN OPTOUT ($n)"
ret=0
$DIG $DIGOPTS +noauth q.optout.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth q.optout.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
# Note - this is looking for failure, hence the &&
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking negative validation NODATA NSEC ($n)"
ret=0
$DIG $DIGOPTS +noauth a.example. @10.53.0.2 txt > dig.out.ns2.test$n || ret=1
$DIG $DIGOPTS +noauth a.example. @10.53.0.4 txt > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns2.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "ANSWER: 0" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking negative validation NODATA NSEC3 ($n)"
ret=0
$DIG $DIGOPTS +noauth a.nsec3.example. \
	@10.53.0.3 txt > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.nsec3.example. \
	@10.53.0.4 txt > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "ANSWER: 0" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking negative validation NODATA OPTOUT ($n)"
ret=0
$DIG $DIGOPTS +noauth a.optout.example. \
	@10.53.0.3 txt > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.optout.example. \
	@10.53.0.4 txt > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "ANSWER: 0" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

# Check the insecure.example domain

echo_i "checking 1-server insecurity proof NSEC ($n)"
ret=0
$DIG $DIGOPTS +noauth a.insecure.example. @10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.insecure.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
# Note - this is looking for failure, hence the &&
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking 1-server negative insecurity proof NSEC ($n)"
ret=0
$DIG $DIGOPTS q.insecure.example. a @10.53.0.3 \
	> dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS q.insecure.example. a @10.53.0.4 \
	> dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
# Note - this is looking for failure, hence the &&
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

# Check the secure.example domain

echo_i "checking multi-stage positive validation NSEC/NSEC ($n)"
ret=0
$DIG $DIGOPTS +noauth a.secure.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.secure.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking multi-stage positive validation NSEC/NSEC3 ($n)"
ret=0
$DIG $DIGOPTS +noauth a.nsec3.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.nsec3.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking multi-stage positive validation NSEC/OPTOUT ($n)"
ret=0
$DIG $DIGOPTS +noauth a.optout.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.optout.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking multi-stage positive validation NSEC3/NSEC ($n)"
ret=0
$DIG $DIGOPTS +noauth a.secure.nsec3.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.secure.nsec3.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking multi-stage positive validation NSEC3/NSEC3 ($n)"
ret=0
$DIG $DIGOPTS +noauth a.nsec3.nsec3.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.nsec3.nsec3.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking multi-stage positive validation NSEC3/OPTOUT ($n)"
ret=0
$DIG $DIGOPTS +noauth a.optout.nsec3.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.optout.nsec3.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking multi-stage positive validation OPTOUT/NSEC ($n)"
ret=0
$DIG $DIGOPTS +noauth a.secure.optout.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.secure.optout.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking multi-stage positive validation OPTOUT/NSEC3 ($n)"
ret=0
$DIG $DIGOPTS +noauth a.nsec3.optout.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.nsec3.optout.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking multi-stage positive validation OPTOUT/OPTOUT ($n)"
ret=0
$DIG $DIGOPTS +noauth a.optout.optout.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.optout.optout.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking empty NODATA OPTOUT ($n)"
ret=0
$DIG $DIGOPTS +noauth empty.optout.example. \
	@10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth empty.optout.example. \
	@10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
#grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

# Check the insecure.secure.example domain (insecurity proof)

echo_i "checking 2-server insecurity proof ($n)"
ret=0
$DIG $DIGOPTS +noauth a.insecure.secure.example. @10.53.0.2 a \
	> dig.out.ns2.test$n || ret=1
$DIG $DIGOPTS +noauth a.insecure.secure.example. @10.53.0.4 a \
	> dig.out.ns4.test$n || ret=1
digcomp dig.out.ns2.test$n dig.out.ns4.test$n || ret=1
grep "status: NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
# Note - this is looking for failure, hence the &&
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

# Check a negative response in insecure.secure.example

echo_i "checking 2-server insecurity proof with a negative answer ($n)"
ret=0
$DIG $DIGOPTS q.insecure.secure.example. @10.53.0.2 a > dig.out.ns2.test$n \
	|| ret=1
$DIG $DIGOPTS q.insecure.secure.example. @10.53.0.4 a > dig.out.ns4.test$n \
	|| ret=1
digcomp dig.out.ns2.test$n dig.out.ns4.test$n || ret=1
grep "status: NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
# Note - this is looking for failure, hence the &&
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking security root query ($n)"
ret=0
$DIG $DIGOPTS . @10.53.0.4 key > dig.out.ns4.test$n || ret=1
grep "NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking positive validation RSASHA256 NSEC ($n)"
ret=0
$DIG $DIGOPTS +noauth a.rsasha256.example. @10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.rsasha256.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking positive validation RSASHA512 NSEC ($n)"
ret=0
$DIG $DIGOPTS +noauth a.rsasha512.example. @10.53.0.3 a > dig.out.ns3.test$n || ret=1
$DIG $DIGOPTS +noauth a.rsasha512.example. @10.53.0.4 a > dig.out.ns4.test$n || ret=1
digcomp dig.out.ns3.test$n dig.out.ns4.test$n || ret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that positive validation in a privately secure zone works ($n)"
ret=0
$DIG $DIGOPTS +noauth a.private.secure.example. a @10.53.0.2 \
	> dig.out.ns2.test$n || ret=1
$DIG $DIGOPTS +noauth a.private.secure.example. a @10.53.0.4 \
	> dig.out.ns4.test$n || ret=1
digcomp dig.out.ns2.test$n dig.out.ns4.test$n || ret=1
grep "NOERROR" dig.out.ns4.test$n > /dev/null || ret=1
# Note - this is looking for failure, hence the &&
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that negative validation in a privately secure zone works ($n)"
ret=0
$DIG $DIGOPTS +noauth q.private.secure.example. a @10.53.0.2 \
	> dig.out.ns2.test$n || ret=1
$DIG $DIGOPTS +noauth q.private.secure.example. a @10.53.0.4 \
	> dig.out.ns4.test$n || ret=1
digcomp dig.out.ns2.test$n dig.out.ns4.test$n || ret=1
grep "NXDOMAIN" dig.out.ns4.test$n > /dev/null || ret=1
# Note - this is looking for failure, hence the &&
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking privately secure to nxdomain works ($n)"
ret=0
$DIG $DIGOPTS +noauth private2secure-nxdomain.private.secure.example. SOA @10.53.0.2 \
	> dig.out.ns2.test$n || ret=1
$DIG $DIGOPTS +noauth private2secure-nxdomain.private.secure.example. SOA @10.53.0.4 \
	> dig.out.ns4.test$n || ret=1
$PERL ../digcomp.pl dig.out.ns2.test$n dig.out.ns4.test$n || ret=1
# Note - this is looking for failure, hence the &&
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

# Try validating with a revoked trusted key.
# This should fail.

echo_i "checking that validation returns insecure due to revoked trusted key ($n)"
ret=0
$DIG $DIGOPTS example. soa @10.53.0.5 > dig.out.ns5.test$n || ret=1
grep "flags:.*; QUERY" dig.out.ns5.test$n > /dev/null || ret=1
grep "flags:.* ad.*; QUERY" dig.out.ns5.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that revoked key is present ($n)"
ret=0
id=`cat rev.key`
$DIG $DIGOPTS +multi dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep '; key id = '"$id"'$' dig.out.ns1.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that revoked key self-signs ($n)"
ret=0
id=`cat rev.key`
$DIG $DIGOPTS dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep 'RRSIG.*'" $id "'\. ' dig.out.ns1.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking for unpublished key ($n)"
ret=0
id=`keyfile_to_key_id \`cat unpub.key\``
$DIG $DIGOPTS +multi dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep '; key id = '"$id"'$' dig.out.ns1.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking for activated but unpublished key ($n)"
ret=0
id=`keyfile_to_key_id \`cat activate-now-publish-1day.key\``
$DIG $DIGOPTS +multi dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep '; key id = '"$id"'$' dig.out.ns1.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that standby key does not sign records ($n)"
ret=0
id=`keyfile_to_key_id \`cat standby.key\``
$DIG $DIGOPTS dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep 'RRSIG.*'" $id "'\. ' dig.out.ns1.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that deactivated key does not sign records  ($n)"
ret=0
id=`keyfile_to_key_id \`cat inact.key\``
$DIG $DIGOPTS dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep 'RRSIG.*'" $id "'\. ' dig.out.ns1.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking insertion of public-only key ($n)"
ret=0
id=`keyfile_to_key_id \`cat nopriv.key\``
file="ns1/`cat nopriv.key`.key"
keydata=`grep DNSKEY $file`
$NSUPDATE > /dev/null 2>&1 <<END	|| status=1
server 10.53.0.1 ${PORT}
zone .
ttl 3600
update add $keydata
send
END
sleep 1
$DIG $DIGOPTS dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep 'RRSIG.*'" $id "'\. ' dig.out.ns1.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking key deletion ($n)"
ret=0
id=`keyfile_to_key_id \`cat del.key\``
$DIG $DIGOPTS +multi dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep '; key id = '"$id"'$' dig.out.ns1.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking secure-to-insecure transition, nsupdate ($n)"
ret=0
$NSUPDATE > /dev/null 2>&1 <<END	|| status=1
server 10.53.0.3 ${PORT}
zone secure-to-insecure.example
update delete secure-to-insecure.example dnskey
send
END
for i in 0 1 2 3 4 5 6 7 8 9; do
	ret=0
	$DIG $DIGOPTS axfr secure-to-insecure.example @10.53.0.3 > dig.out.ns3.test$n || ret=1
	egrep '(RRSIG|DNSKEY|NSEC)' dig.out.ns3.test$n > /dev/null && ret=1
	[ $ret -eq 0 ] && break
	echo_i "waiting ... ($i)"
	sleep 2
done
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking secure-to-insecure transition, scheduled ($n)"
ret=0
file="ns3/`cat del1.key`.key"
$SETTIME -I now -D now $file > settime.out.test$n.1 || ret=1
file="ns3/`cat del2.key`.key"
$SETTIME -I now -D now $file > settime.out.test$n.2 || ret=1
($RNDCCMD 10.53.0.3 sign secure-to-insecure2.example. 2>&1 | sed 's/^/ns3 /' | cat_i) || ret=1
for i in 0 1 2 3 4 5 6 7 8 9; do
	ret=0
	$DIG $DIGOPTS axfr secure-to-insecure2.example @10.53.0.3 > dig.out.ns3.test$n || ret=1
	egrep '(RRSIG|DNSKEY|NSEC3)' dig.out.ns3.test$n > /dev/null && ret=1
	[ $ret -eq 0 ] && break
	echo_i "waiting ... ($i)"
	sleep 2
done
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking jitter in a newly signed NSEC3 zone ($n)"
ret=0
# Use DNS UPDATE to add an NSEC3PARAM record into the zone.
$NSUPDATE > nsupdate.out.test$n 2>&1 <<END || ret=1
server 10.53.0.3 ${PORT}
zone jitter.nsec3.example.
update add jitter.nsec3.example. 3600 NSEC3PARAM 1 0 10 BEEF
send
END
[ $ret != 0 ] && echo_i "error: dynamic update add NSEC3PARAM failed"
# Create DNSSEC keys in the zone directory.
$KEYGEN -r $RANDFILE -a rsasha256 -b 2048 -3 -q -K ns3 jitter.nsec3.example > /dev/null
# Trigger zone signing.
($RNDCCMD 10.53.0.3 sign jitter.nsec3.example. 2>&1 | sed 's/^/ns3 /' | cat_i) || ret=1
# Wait until zone has been signed.
check_if_nsec3param_exists() {
	$DIG $DIGOPTS NSEC3PARAM jitter.nsec3.example @10.53.0.3 > dig.out.ns3.1.test$n || return 1
	grep -q "^jitter\.nsec3\.example\..*NSEC3PARAM" dig.out.ns3.1.test$n || return 1
}
retry_quiet 40 check_if_nsec3param_exists || {
	echo_i "error: NSEC3PARAM not present yet"
	ret=1
}
$DIG $DIGOPTS AXFR jitter.nsec3.example @10.53.0.3 > dig.out.ns3.2.test$n || ret=1
# Check jitter distribution.
checkjitter dig.out.ns3.2.test$n || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that serial number and RRSIGs are both updated (rt21045) ($n)"
ret=0
oldserial=`$DIG $DIGOPTS +short soa prepub.example @10.53.0.3 | awk '$0 !~ /SOA/ {print $3}'`
oldinception=`$DIG $DIGOPTS +short soa prepub.example @10.53.0.3 | awk '/SOA/ {print $6}' | sort -u`

$KEYGEN -3 -q -r $RANDFILE -K ns3 -P 0 -A +6d -I +38d -D +45d prepub.example > /dev/null

($RNDCCMD 10.53.0.3 sign prepub.example 2>&1 | sed 's/^/ns1 /' | cat_i) || ret=1
newserial=$oldserial
try=0
while [ $oldserial -eq $newserial -a $try -lt 42 ]
do
	newserial=`$DIG $DIGOPTS +short soa prepub.example @10.53.0.3 |
		 awk '$0 !~ /SOA/ {print $3}'`
	sleep 1
	try=`expr $try + 1`
done
newinception=`$DIG $DIGOPTS +short soa prepub.example @10.53.0.3 | awk '/SOA/ {print $6}' | sort -u`
#echo "$oldserial : $newserial"
#echo "$oldinception : $newinception"

[ "$oldserial" = "$newserial" ] && ret=1
[ "$oldinception" = "$newinception" ] && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "preparing to test key change corner cases"
echo_i "removing a private key file"
file="ns1/`cat vanishing.key`.private"
rm -f $file

echo_i "preparing ZSK roll"
starttime=`$PERL -e 'print time(), "\n";'`
oldfile=`cat active.key`
oldid=`keyfile_to_key_id \`cat active.key\``
newfile=`cat standby.key`
newid=`keyfile_to_key_id \`cat standby.key\``
$SETTIME -K ns1 -I now+2s -D now+25 $oldfile > settime.out.test$n.1 || ret=1
$SETTIME -K ns1 -i 0 -S $oldfile $newfile > settime.out.test$n.2 || ret=1

# note previous zone serial number
oldserial=`$DIG $DIGOPTS +short soa . @10.53.0.1 | awk '{print $3}'`

($RNDCCMD 10.53.0.1 loadkeys . 2>&1 | sed 's/^/ns1 /' | cat_i) || ret=1
sleep 4

echo_i "revoking key to duplicated key ID"
$SETTIME -R now -K ns2 Kbar.+005+30676.key > settime.out.test$n.3 || ret=1

($RNDCCMD 10.53.0.2 loadkeys bar. 2>&1 | sed 's/^/ns2 /' | cat_i) || ret=1

echo_i "waiting for changes to take effect"
sleep 5

echo_i "checking former standby key $newid is now active ($n)"
ret=0
$DIG $DIGOPTS dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep 'RRSIG.*'" $newid "'\. ' dig.out.ns1.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking former standby key has only signed incrementally ($n)"
ret=0
$DIG $DIGOPTS txt . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep 'RRSIG.*'" $newid "'\. ' dig.out.ns1.test$n > /dev/null && ret=1
grep 'RRSIG.*'" $oldid "'\. ' dig.out.ns1.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that signing records have been marked as complete ($n)"
ret=0
checkprivate . 10.53.0.1 || ret=1
checkprivate bar 10.53.0.2 || ret=1
checkprivate example 10.53.0.2 || ret=1
checkprivate private.secure.example 10.53.0.3 || ret=1
checkprivate nsec3.example 10.53.0.3 || ret=1
checkprivate nsec3.nsec3.example 10.53.0.3 || ret=1
checkprivate nsec3.optout.example 10.53.0.3 || ret=1
checkprivate nsec3-to-nsec.example 10.53.0.3 || ret=1
checkprivate nsec.example 10.53.0.3 || ret=1
checkprivate oldsigs.example 10.53.0.3 || ret=1
checkprivate optout.example 10.53.0.3 || ret=1
checkprivate optout.nsec3.example 10.53.0.3 || ret=1
checkprivate optout.optout.example 10.53.0.3 || ret=1
checkprivate prepub.example 10.53.0.3 1 || ret=1
checkprivate rsasha256.example 10.53.0.3 || ret=1
checkprivate rsasha512.example 10.53.0.3 || ret=1
checkprivate secure.example 10.53.0.3 || ret=1
checkprivate secure.nsec3.example 10.53.0.3 || ret=1
checkprivate secure.optout.example 10.53.0.3 || ret=1
checkprivate secure-to-insecure2.example 10.53.0.3 || ret=1
checkprivate secure-to-insecure.example 10.53.0.3 || ret=1
checkprivate ttl1.example 10.53.0.3 || ret=1
checkprivate ttl2.example 10.53.0.3 || ret=1
checkprivate ttl3.example 10.53.0.3 || ret=1
checkprivate ttl4.example 10.53.0.3 || ret=1
n=`expr $n + 1`
status=`expr $status + $ret`

echo_i "forcing full sign"
($RNDCCMD 10.53.0.1 sign . 2>&1 | sed 's/^/ns1 /' | cat_i) || ret=1

echo_i "waiting for change to take effect"
sleep 5

echo_i "checking former standby key has now signed fully ($n)"
ret=0
$DIG $DIGOPTS txt . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep 'RRSIG.*'" $newid "'\. ' dig.out.ns1.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking SOA serial number has been incremented ($n)"
ret=0
newserial=`$DIG $DIGOPTS +short soa . @10.53.0.1 | awk '{print $3}'`
[ "$newserial" != "$oldserial" ] || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking delayed key publication/activation ($n)"
ret=0
zsk=`cat delayzsk.key`
ksk=`cat delayksk.key`
# publication and activation times should be unset
$SETTIME -K ns3 -pA -pP $zsk > settime.out.test$n.zsk || ret=1
grep -v UNSET settime.out.test$n.zsk >/dev/null && ret=1
$SETTIME -K ns3 -pA -pP $ksk > settime.out.test$n.ksk || ret=1
grep -v UNSET settime.out.test$n.ksk >/dev/null && ret=1
$DIG $DIGOPTS +noall +answer dnskey delay.example. @10.53.0.3 > dig.out.ns3.test$n || ret=1
# DNSKEY not expected:
awk 'BEGIN {r=1} $4=="DNSKEY" {r=0} END {exit r}' dig.out.ns3.test$n && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking scheduled key publication, not activation ($n)"
ret=0
# Ensure initial zone is loaded.
wait_for_notifies "delay.example" "ns3" || ret=1
$SETTIME -K ns3 -P now+3s -A none $zsk > settime.out.test$n.zsk || ret=1
$SETTIME -K ns3 -P now+3s -A none $ksk > settime.out.test$n.ksk || ret=1
($RNDCCMD 10.53.0.3 loadkeys delay.example. 2>&1 | sed 's/^/ns2 /' | cat_i) || ret=1
echo_i "waiting for changes to take effect"
sleep 3
wait_for_notifies "delay.example" "ns3" || ret=1

$DIG $DIGOPTS +noall +answer dnskey delay.example. @10.53.0.3 > dig.out.ns3.test$n || ret=1
# DNSKEY expected:
awk 'BEGIN {r=1} $4=="DNSKEY" {r=0} END {exit r}' dig.out.ns3.test$n || ret=1
# RRSIG not expected:
awk 'BEGIN {r=1} $4=="RRSIG" {r=0} END {exit r}' dig.out.ns3.test$n && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking scheduled key activation ($n)"
ret=0
$SETTIME -K ns3 -A now+3s $zsk > settime.out.test$n.zsk || ret=1
$SETTIME -K ns3 -A now+3s $ksk > settime.out.test$n.ksk || ret=1
($RNDCCMD 10.53.0.3 loadkeys delay.example. 2>&1 | sed 's/^/ns2 /' | cat_i) || ret=1
echo_i "waiting for changes to take effect"
sleep 3
wait_for_log "add delay\.example\..*NSEC.a\.delay\.example\. NS SOA RRSIG NSEC DNSKEY" ns3/named.run
$DIG $DIGOPTS +noall +answer dnskey delay.example. @10.53.0.3 > dig.out.ns3.1.test$n || ret=1
# DNSKEY expected:
awk 'BEGIN {r=1} $4=="DNSKEY" {r=0} END {exit r}' dig.out.ns3.1.test$n || ret=1
# RRSIG expected:
awk 'BEGIN {r=1} $4=="RRSIG" {r=0} END {exit r}' dig.out.ns3.1.test$n || ret=1
$DIG $DIGOPTS +noall +answer a a.delay.example. @10.53.0.3 > dig.out.ns3.2.test$n || ret=1
# A expected:
awk 'BEGIN {r=1} $4=="A" {r=0} END {exit r}' dig.out.ns3.2.test$n || ret=1
# RRSIG expected:
awk 'BEGIN {r=1} $4=="RRSIG" {r=0} END {exit r}' dig.out.ns3.2.test$n || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking former active key was removed ($n)"
#
# Work out how long we need to sleep. Allow 4 seconds for the records
# to be removed.
#
now=`$PERL -e 'print time(), "\n";'`
sleep=`expr $starttime + 29 - $now`
case $sleep in
-*|0);;
*) echo_i "waiting for timer to have activated"; sleep $sleep;;
esac
ret=0
$DIG $DIGOPTS +multi dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep '; key id = '"$oldid"'$' dig.out.ns1.test$n > /dev/null && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking private key file removal caused no immediate harm ($n)"
ret=0
id=`keyfile_to_key_id \`cat vanishing.key\``
$DIG $DIGOPTS dnskey . @10.53.0.1 > dig.out.ns1.test$n || ret=1
grep 'RRSIG.*'" $id "'\. ' dig.out.ns1.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking revoked key with duplicate key ID (failure expected) ($n)"
lret=0
id=30676
$DIG $DIGOPTS +multi dnskey bar @10.53.0.2 > dig.out.ns2.test$n || lret=1
grep '; key id = '"$id"'$' dig.out.ns2.test$n > /dev/null || lret=1
$DIG $DIGOPTS dnskey bar @10.53.0.4 > dig.out.ns4.test$n || lret=1
grep "flags:.*ad.*QUERY" dig.out.ns4.test$n > /dev/null || lret=1
n=`expr $n + 1`
if [ $lret != 0 ]; then echo_i "not yet implemented"; fi

echo_i "checking key event timers are always set ($n)"
# this is a regression test for a bug in which the next key event could
# be scheduled for the present moment, and then never fire.  check for
# visible evidence of this error in the logs:
awk '/next key event/ {if ($1 == $8 && $2 == $9) exit 1}' */named.run || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

# this confirms that key events are never scheduled more than
# 'dnssec-loadkeys-interval' minutes in the future, and that the
# event scheduled is within 10 seconds of expected interval.
check_interval () {
        awk '/next key event/ {print $2 ":" $9}' $1/named.run |
	sed -e 's/\.//g' -e 's/:0\{1,4\}/:/g' |
            awk -F: '
                     {
                       x = ($6+ $5*60000 + $4*3600000) - ($3+ $2*60000 + $1*3600000);
		       # abs(x) < 1000 ms treat as 'now'
		       if (x < 1000 && x > -1000)
                         x = 0;
		       # convert to seconds
		       x = x/1000;
		       # handle end of day roll over
		       if (x < 0)
			 x = x + 24*3600;
		       # handle log timestamp being a few milliseconds later
                       if (x != int(x))
                         x = int(x + 1);
                       if (int(x) > int(interval))
                         exit (1);
                     }
                     END { if (int(x) > int(interval) || int(x) < int(interval-10)) exit(1) }' interval=$2
        return $?
}

echo_i "checking automatic key reloading interval ($n)"
ret=0
check_interval ns1 3600 || ret=1
check_interval ns2 1800 || ret=1
check_interval ns3 600 || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking for key reloading loops ($n)"
ret=0
# every key event should schedule a successor, so these should be equal
rekey_calls=`grep "reconfiguring zone keys" ns*/named.run | wc -l`
rekey_events=`grep "next key event" ns*/named.run | wc -l`
[ "$rekey_calls" = "$rekey_events" ] || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "forcing full sign with unreadable keys ($n)"
ret=0
chmod 0 ns1/K.+*+*.key ns1/K.+*+*.private || ret=1
($RNDCCMD 10.53.0.1 sign . 2>&1 | sed 's/^/ns1 /' | cat_i) || ret=1
$DIG $DIGOPTS . @10.53.0.1 dnskey > dig.out.ns1.test$n || ret=1
grep "status: NOERROR" dig.out.ns1.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "test turning on auto-dnssec during reconfig ($n)"
ret=0
# first create a zone that doesn't have auto-dnssec
($RNDCCMD 10.53.0.3 addzone reconf.example '{ type master; file "reconf.example.db"; };' 2>&1 | sed 's/^/ns3 /' | cat_i) || ret=1
rekey_calls=`grep "zone reconf.example.*next key event" ns3/named.run | wc -l`
[ "$rekey_calls" -eq 0 ] || ret=1
# ...then we add auto-dnssec and reconfigure
($RNDCCMD 10.53.0.3 modzone reconf.example '{ type master; file "reconf.example.db"; allow-update { any; }; auto-dnssec maintain; };' 2>&1 | sed 's/^/ns3 /' | cat_i) || ret=1
$RNDCCMD 10.53.0.3 reconfig 2>&1 | sed 's/^/ns3 /' | cat_i
for i in 0 1 2 3 4 5 6 7 8 9; do
    lret=0
    rekey_calls=`grep "zone reconf.example.*next key event" ns3/named.run | wc -l`
    [ "$rekey_calls" -gt 0 ] || lret=1
    if [ "$lret" -eq 0 ]; then break; fi
    echo_i "waiting ... ($i)"
    sleep 1
done
n=`expr $n + 1`
if [ "$lret" != 0 ]; then ret=$lret; fi
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "test CDS and CDNSKEY auto generation ($n)"
ret=0
$DIG $DIGOPTS @10.53.0.3 sync.example cds > dig.out.ns3.cdstest$n
$DIG $DIGOPTS @10.53.0.3 sync.example cdnskey > dig.out.ns3.cdnskeytest$n
grep -i "sync.example.*in.cds.*[1-9][0-9]* " dig.out.ns3.cdstest$n > /dev/null || ret=1
grep -i "sync.example.*in.cdnskey.*257 " dig.out.ns3.cdnskeytest$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "setting CDS and CDNSKEY deletion times and calling 'rndc loadkeys'"
$SETTIME -D sync now+2 `cat sync.key` > settime.out.test$n || ret=1
($RNDCCMD 10.53.0.3 loadkeys sync.example | sed 's/^/ns3 /' | cat_i) || ret=1

echo_i "checking that the CDS and CDNSKEY are deleted ($n)"
ret=0
ensure_cds_and_cdnskey_are_deleted() {
	$DIG $DIGOPTS @10.53.0.3 sync.example. CDS > dig.out.ns3.cdstest$n || return 1
	awk '$1 == "sync.example." && $4 == "CDS" { exit 1; }' dig.out.ns3.cdstest$n || return 1
	$DIG $DIGOPTS @10.53.0.3 sync.example. CDNSKEY > dig.out.ns3.cdnskeytest$n || return 1
	awk '$1 == "sync.example." && $4 == "CDNSKEY" { exit 1; }' dig.out.ns3.cdnskeytest$n || return 1
}
retry 10 ensure_cds_and_cdnskey_are_deleted || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "check that dnssec-settime -p Dsync works ($n)"
ret=0
$SETTIME -p Dsync `cat sync.key` > settime.out.test$n || ret=1
grep "SYNC Delete:" settime.out.test$n >/dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "check that dnssec-settime -p Psync works ($n)"
ret=0
$SETTIME -p Psync `cat sync.key` > settime.out.test$n || ret=1
grep "SYNC Publish:" settime.out.test$n >/dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "check that zone with inactive KSK and active ZSK is properly autosigned ($n)"
ret=0
$DIG $DIGOPTS @10.53.0.3 axfr inacksk2.example > dig.out.ns3.test$n

zskid=`awk '$4 == "DNSKEY" && $5 == 256 { print }' dig.out.ns3.test$n |
       $DSFROMKEY -A -2 -f - inacksk2.example | awk '{ print $4}' `
pattern="DNSKEY 7 2 [0-9]* [0-9]* [0-9]* ${zskid} "
grep "${pattern}" dig.out.ns3.test$n > /dev/null || ret=1

kskid=`awk '$4 == "DNSKEY" && $5 == 257 { print }' dig.out.ns3.test$n |
       $DSFROMKEY -2 -f - inacksk2.example | awk '{ print $4}' `
pattern="DNSKEY 7 2 [0-9]* [0-9]* [0-9]* ${kskid} "
grep "${pattern}" dig.out.ns3.test$n > /dev/null && ret=1

n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "check that zone with inactive ZSK and active KSK is properly autosigned ($n)"
ret=0
$DIG $DIGOPTS @10.53.0.3 axfr inaczsk2.example > dig.out.ns3.test$n
grep "SOA 7 2" dig.out.ns3.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

#
# Check that DNSKEY is now signed with the ZSK.
#
echo_i "check that zone with active and inactive KSK and active ZSK is properly"
echo_ic "resigned after the active KSK is deleted - stage 2: Verify that DNSKEY"
echo_ic "is now signed with the ZSK. ($n)"
ret=0

$DIG $DIGOPTS @10.53.0.3 axfr inacksk3.example > dig.out.ns3.test$n

zskid=`awk '$4 == "DNSKEY" && $5 == 256 { print }' dig.out.ns3.test$n |
       $DSFROMKEY -A -2 -f - inacksk3.example | awk '{ print $4}' `
pattern="DNSKEY 7 2 [0-9]* [0-9]* [0-9]* ${zskid} "
grep "${pattern}" dig.out.ns3.test$n > /dev/null || ret=1

count=`awk 'BEGIN { count = 0 }
       $4 == "RRSIG" && $5 == "DNSKEY" { count++ }
       END {print count}' dig.out.ns3.test$n`
test $count -eq 1 || ret=1

count=`awk 'BEGIN { count = 0 }
       $4 == "DNSKEY" { count++ }
       END {print count}' dig.out.ns3.test$n`
test $count -eq 2 || ret=1

n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

#
# Check that zone is now signed with the KSK.
#
echo_i "check that zone with active and inactive ZSK and active KSK is properly"
echo_ic "resigned after the active ZSK is deleted - stage 2: Verify that zone"
echo_ic "is now signed with the KSK. ($n)"
ret=0
$DIG $DIGOPTS @10.53.0.3 axfr inaczsk3.example > dig.out.ns3.test$n
kskid=`awk '$4 == "DNSKEY" && $5 == 257 { print }' dig.out.ns3.test$n |
       $DSFROMKEY -2 -f - inaczsk3.example | awk '{ print $4}' `
grep "CNAME 7 3 [0-9]* [0-9]* [0-9]* ${kskid} " dig.out.ns3.test$n > /dev/null || ret=1
count=`awk 'BEGIN { count = 0 }
       $4 == "RRSIG" && $5 == "CNAME" { count++ }
       END {print count}' dig.out.ns3.test$n`
test $count -eq 1 || ret=1
count=`awk 'BEGIN { count = 0 }
       $4 == "DNSKEY" { count++ }
       END {print count}' dig.out.ns3.test$n`
test $count -eq 2 || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking for out-of-zone NSEC3 records after ZSK removal ($n)"
ret=0
# Switch the zone over to NSEC3 and wait until the transition is complete.
$RNDCCMD 10.53.0.3 signing -nsec3param 1 1 10 12345678 delzsk.example. > signing.out.1.test$n 2>&1 || ret=1
for i in 0 1 2 3 4 5 6 7 8 9; do
	_ret=1
	$DIG $DIGOPTS delzsk.example NSEC3PARAM @10.53.0.3 > dig.out.ns3.1.test$n 2>&1 || ret=1
	grep "NSEC3PARAM.*12345678" dig.out.ns3.1.test$n > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		$RNDCCMD 10.53.0.3 signing -list delzsk.example > signing.out.2.test$n 2>&1
		grep "Creating NSEC3 chain " signing.out.2.test$n > /dev/null 2>&1
		if [ $? -ne 0 ]; then
			_ret=0
			break
		fi
	fi
	sleep 1
done
if [ $_ret -ne 0 ]; then
	echo_i "timed out waiting for NSEC3 chain creation"
	ret=1
fi
# Mark the inactive ZSK as pending removal.
file="ns3/`cat delzsk.key`.key"
$SETTIME -D now-1h $file > settime.out.test$n || ret=1
# Trigger removal of the inactive ZSK and wait until its completion.
($RNDCCMD 10.53.0.3 loadkeys delzsk.example 2>&1 | sed 's/^/ns3 /' | cat_i) || ret=1
for i in 0 1 2 3 4 5 6 7 8 9; do
	_ret=1
	$RNDCCMD 10.53.0.3 signing -list delzsk.example > signing.out.3.test$n 2>&1
	grep "Signing " signing.out.3.test$n > /dev/null 2>&1
	if [ $? -ne 0 ]; then
		if [ `grep "Done signing " signing.out.3.test$n | wc -l` -eq 2 ]; then
			_ret=0
			break
		fi
	fi
	sleep 1
done
if [ $_ret -ne 0 ]; then
	echo_i "timed out waiting for key removal"
	ret=1
fi
# Check whether key removal caused NSEC3 records to be erroneously created for
# glue records due to a secure delegation already being signed by the active key
# (i.e. a key other than the one being removed but using the same algorithm).
#
# For reference:
#
#     $ nsec3hash 12345678 1 10 ns.sub.delzsk.example.
#     589R358VSPJUFVAJU949JPVF74D9PTGH (salt=12345678, hash=1, iterations=10)
#
$DIG $DIGOPTS delzsk.example AXFR @10.53.0.3 > dig.out.ns3.3.test$n || ret=1
grep "589R358VSPJUFVAJU949JPVF74D9PTGH" dig.out.ns3.3.test$n > /dev/null 2>&1 && ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "check that DNAME at apex with NSEC3 is correctly signed (auto-dnssec maintain) ($n)"
ret=0
$DIG $DIGOPTS txt dname-at-apex-nsec3.example @10.53.0.3 > dig.out.ns3.test$n || ret=1
grep "RRSIG NSEC3 7 3 3600" dig.out.ns3.test$n > /dev/null || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "checking that DNAME is not treated as a delegation when signing ($n)"
ret=0
$DIG $DIGOPTS dname-and-txt.secure.example. DNAME @10.53.0.3 > dig.out.ns3.1.test$n || ret=1
grep "dname-and-txt.secure.example.*RRSIG.*DNAME" dig.out.ns3.1.test$n > /dev/null 2>&1 || ret=1
$DIG $DIGOPTS dname-and-txt.secure.example. TXT @10.53.0.3 > dig.out.ns3.2.test$n || ret=1
grep "dname-and-txt.secure.example.*RRSIG.*TXT" dig.out.ns3.2.test$n > /dev/null 2>&1 || ret=1
n=`expr $n + 1`
if [ $ret != 0 ]; then echo_i "failed"; fi
status=`expr $status + $ret`

echo_i "exit status: $status"
[ $status -eq 0 ] || exit 1