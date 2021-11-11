#!/bin/bash
# ------------------------------------------------------------------------------------------------
# Usage:
# This script run continuously to attempt to create a balanced node.
# The main idea is to keep minimial liquidity on each channel to at least route some payments.
# The user is expected to customise the script with respect to fees and other parameters. These are
# Available to edit on top of the script. 
#
# It can be executed in a TMUX session continuously as 
# while true; do . <path_to_script>/autorebalance.sh; done
# Or
# It can be executed as a daily cron job.
#
# BOS (Balance of Satoshi) > 10.20.0 (latest version) needs to be installed
#
# Add the following in crontab to run regulary. Change path as appropriate
# 42 21 * * * <path_to_script>/autorebalance.sh >> ~/autorebalance.log 2>&1
# Version: 0.0.2
# Author:  VS https://t.me/BhaagBoseDk 
# 0.0.1 - first version
# 0.0.2 - Added Tip for fun
# 0.0.3 - Handling various bos instllations
# 0.0.4 - Improvement after bos 10.20.0
# 0.1.0 - Reduced Sleep Time, minor varibale name change, other minor updates
# 0.1.1 - Placeholder for customised rebalances; added Out->In rebalcne for heavy local;
#         change to array from local file
#	  use of temporary in memory file system for working directories
# 0.1.2	- use bos call to get MY_KEY
#       - bugfix with temp directory to use PWD if temp area not created.
# 0.1.3 - use special bos tags in peer selection if defined.
# 0.1.4 - allow multiple bos tags
# 0.1.5 - bug fixes in peer selection
#       - only use active nodes
#       - Indicate the executing step number.
# 0.1.6 - Do a nudge to idle peers
#       - bos version 11.10.0
#
# 	<future_wip>
#
# ------------------------------------------------------------------------------------------------
#

script_ver=0.1.6

min_bos_ver=11.10.0

DEBUG=echo

# Change These Parameters as per your requirements

#If you DO NOT wish to tip 1 sat to author each time you run this script make this value 0. If you wish to increase the tip, change to whatever you want. 
TIP=1

# Max_Fee is kept as high since we will control the rebalance with fee-rate. Change if reuired.
MAX_FEE=50000

# Max Fee you want to pay for rebalance.
MAX_FEE_RATE=199

# Fee used to avoid expensive channels into you.
LIMIT_FEE_RATE=199

#High Fees are used in Step 3 and 4. Keep same if you want
HIGH_MAX_FEE_RATE=399
HIGH_LIMIT_FEE_RATE=399

#Loop fees are used for LOOP rebalance
LOOP_MAX_FEE_RATE=2500
LOOP_LIMIT_FEE_RATE=2000

#Consider these channels for decreasing local balance (move to remote) when outbound is above this limit
OUT_OVER_CAPACITY=0.7

# Target rebalance to this capacity of Local. Keep this below 0.5 (50%)
IN_TARGET_OUTBOUND=0.2

# Add in AVOID conditions you want to add to all rebalances
AVOID=" "

# Peers to be omitted from outbound remabalancing. Add to --omit pubkey --omit pubkey syntax. If not specified all peers are considered
OMIT_OUT=" "

# Peers to be omitted from inbound remabalancing. Add to --omit pubkey --omit pubkey syntax. If not specified all peers are considered
OMIT_IN=" "

#Special bos tags
# ab_for_out : peers you prefer to keep local - increaes local if possible. These will not be used as --out
# ab_for_in : peers you prefer to keep remote - increase remote if possible. These will not be use as --in

# Change the tag name here if you have other names for similar purpose you can add multiple with --tag tagname syntax. Make it " " if no tags are required.
TAG_FOR_OUT="--tag ab_for_out"
TAG_FOR_IN="--tag ab_for_in"

#Not used right now. For future.
MINIMUM_LIQUIDITY=250000

#If you run bos in a specific manner or have alias defined for bos, type the same here and uncomment the line (replace #myBOS= by myBOS= and provide your bos path)
#myBOS="your installation specific way to run bos"

#PubKey for LOOP
LOOP="021c97a90a411ff2b10dc2a8e32de2f29d2fa49d41bfbb52bd416e460db0747d0d"

#Idle Days for nudge
IDLE_DAYS=30

# ------------ START OF SCRIPT ------------
#Set possible BOS paths

if [ -f $HOME/.npm-global/bin/bos ] 
then
        BOS="$HOME/.npm-global/bin/bos"
else
        BOS=`which bos`
fi

if [ "$BOS" == "" ] || [ ! -f $BOS ]
then
	if [ "`uname -a | grep umbrel`" != "" ]
        then 
		# Potential Docker Installation on umbrel
		BOS="docker run --rm --network=host --add-host=umbrel.local:10.21.21.9 -v $HOME/.bos:/home/node/.bos -v $HOME/umbrel/lnd:/home/node/.lnd:ro alexbosworth/balanceofsatoshis"
	else
		#Other installations
		BOS="docker run --rm --network="generated_default" -v $HOME/.bos:/home/node/.bos alexbosworth/balanceofsatoshis balance"
	fi
fi

if [ "$myBOS" != "" ]
then
	BOS=$myBOS
fi

#BOS=user_specific_path for bos

echo "========= START UP ==========="
echo "==== version $script_ver ===="
date

bos_ver=`$BOS -V`
echo "BOS is $BOS $bos_ver"

if [[ "$bos_ver" < "$min_bos_ver" ]] 
then
 echo "Error -1 : Please upgrade latest bos version equal or higher than $min_bos_ver" 
 exit -1
fi

MY_KEY=`$BOS call getidentity | sed "s,\x1B\[[0-9;]*[a-zA-Z],,g" | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}' | tail -1`

echo "My node pub key ..... $MY_KEY"

#These are temporary directories used by the script
if [  -d /run/user/$(id -u) ]
then
 T_DIR="--tmpdir=/run/user/$(id -u)"
else
 #Use Current Directory as temp area
 T_DIR="--tmpdir=."
fi

MY_T_DIR=$(mktemp -dt "autorebalance.XXXXXXXX" $T_DIR)

echo "Temporary Working Area $MY_T_DIR ... if you terminate the script, do remember to clean manually"

#Get current peers
if [ -d ~/utils ]
then
 cp ~/utils/peers $MY_T_DIR/
else
 $BOS peers > $MY_T_DIR/peers 2>&1
fi

if [ "$TAG_FOR_OUT" != " " ]
then
 forout_arr=(`$BOS peers --no-color --complete --active $TAG_FOR_OUT \
 | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`) 

 echo "Working with ${#forout_arr[@]} special peers to keep local, do not use in --out"
fi

if [ ${#forout_arr[@]} -ne 0 ]
then
 # Add to OMIT_OUT
 for i in "${forout_arr[@]}"
  do
   OMIT_OUT="--omit "$i" "$OMIT_OUT
  done
fi

#$DEBUG $OMIT_OUT

if [ "$TAG_FOR_IN" != " " ]
then
 forin_arr=(`$BOS peers --no-color --complete --active $TAG_FOR_IN \
 | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`) 

 echo "Working with ${#forin_arr[@]} special peers to keep remote, do not use in --in"
fi

if [ ${#forin_arr[@]} -ne 0 ]
then 
 # Add to OMIT_IN
 for i in "${forin_arr[@]}"
  do
   OMIT_IN="--omit "$i" "$OMIT_IN
  done
fi

#$DEBUG $OMIT_IN

if [ $IDLE_DAYS > 0 ]
then
 idle_arr=(`$BOS peers --no-color --complete --active --idle-days $IDLE_DAYS \
 | grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`) 

 echo "Working with ${#idle_arr[@]} idle peers to shake up"
fi

#Get peers with high outbound

sendout_arr=(`$BOS peers --no-color --complete --active --sort inbound_liquidity --filter "OUTBOUND_LIQUIDITY>(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$OUT_OVER_CAPACITY" $OMIT_OUT \
| grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`) 

#Add peers which we prefer to send out
sendout_arr+=(${forin_arr[@]})

#Get all low outbound channels 80% below minimum to increase local.
bringin_arr=(`$BOS peers --no-color --complete --active --sort outbound_liquidity --filter "OUTBOUND_LIQUIDITY<(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$IN_TARGET_OUTBOUND*8/10" $OMIT_IN \
| grep public_key: | grep -v partner_ | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}'`)

#Add peers which we prefer to bring in
bringin_arr+=(${forout_arr[@]})

if [ ${#sendout_arr[@]} -eq 0 ] 
then
 echo "Error -1 : No outbound peers available for rebalance. Consider lowering OUT_OVER_CAPACITY from "$OUT_OVER_CAPACITY
 exit -1
fi

if [ ${#bringin_arr[@]} -eq 0 ] 
then
 echo "Error -1 : No inbound peers available for rebalance. Consider lowering IN_TARGET_OUTBOUND from "$IN_TARGET_OUTBOUND
 exit -1
fi

echo "Step 0 ... Nudging idle peers to CAPACITY/2"
echo "Working with ${#idle_arr[@]} peers to increase balance to CAPACITY/2 inbound via ${#bringin_arr[@]} peers to decrease inbound"

for OUT in "${idle_arr[@]}"; do \
 j=$(($RANDOM % ${#bringin_arr[@]}));
 #Select A random in peer
 IN=${bringin_arr[j]};

 echo -e "\n 0.out------> "$OUT"\n";  grep $OUT $MY_T_DIR/peers | tail -7;

 echo -e "\n 0.in-------> "$IN"\n"; grep $IN $MY_T_DIR/peers | tail -7;

 $BOS rebalance --in $IN --out $OUT --out-target-inbound CAPACITY/2 --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --avoid "$OUT/FEE_RATE>$LIMIT_FEE_RATE" --max-fee-rate $MAX_FEE_RATE --max-fee $MAX_FEE $AVOID;\
 date; sleep 1;

 #Send message to peer randomly once in 10000 times

 j=$(($RANDOM % 10000));
 #echo $j
 if [ $j = 6942 ]
 then 
  $BOS send $OUT --amount 1 --max-fee 1 --message "No activity bewteen our channel for 30 days. Please review. Love from $MY_KEY" 
 fi
done

# Rebalance with a random outbound node 

echo "Step 1 ... Ensure Local balance if channel local balance is < $IN_TARGET_OUTBOUND"
echo "Working with ${#bringin_arr[@]} peers to increase outbound via ${#sendout_arr[@]} peers to decrease outbound"

for IN in "${bringin_arr[@]}"; do \
 j=$(($RANDOM % ${#sendout_arr[@]}));
 #Select A random out peer
 OUT=${sendout_arr[j]};

 echo -e "\n 1.out------> "$OUT"\n";  grep $OUT $MY_T_DIR/peers | tail -7;

 echo -e "\n 1.in-------> "$IN"\n"; grep $IN $MY_T_DIR/peers | tail -7;

 $BOS rebalance --in $IN --out $OUT --in-target-outbound CAPACITY*$IN_TARGET_OUTBOUND --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --avoid "$OUT/FEE_RATE>$LIMIT_FEE_RATE" --max-fee-rate $MAX_FEE_RATE --max-fee $MAX_FEE $AVOID;\
 date; sleep 1;
done

echo "Step 2 ... Reducing outbound for channels with outbound  > $OUT_OVER_CAPACITY to CAPACITY/2"
echo "Working with ${#sendout_arr[@]} peers to increase inbound via ${#bringin_arr[@]} peers to decrease inbound"

for OUT in "${sendout_arr[@]}"; do \
 j=$(($RANDOM % ${#bringin_arr[@]}));
 #Select A random in peer
 IN=${bringin_arr[j]};

 echo -e "\n 2.out------> "$OUT"\n";  grep $OUT $MY_T_DIR/peers | tail -7;

 echo -e "\n 2.in-------> "$IN"\n"; grep $IN $MY_T_DIR/peers | tail -7;

 $BOS rebalance --in $IN --out $OUT --out-target-inbound CAPACITY/2 --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --avoid "$OUT/FEE_RATE>$LIMIT_FEE_RATE" --max-fee-rate $MAX_FEE_RATE --max-fee $MAX_FEE $AVOID;\
 date; sleep 1;
done

#The following rebalances are done spefically for ab_for_out and ab_for_in tags. You might want to change the fees if you prefer.

MAX_FEE_RATE=$HIGH_MAX_FEE_RATE
LIMIT_FEE_RATE=$HIGH_LIMIT_FEE_RATE

echo "Step 3 ... Increasing outbound for channels we prefer to keep local"
echo "Working with ${#forout_arr[@]} peers to increase outbound via ${#sendout_arr[@]} peers to decrease outbound"

for IN in "${forout_arr[@]}"; do \
 j=$(($RANDOM % ${#sendout_arr[@]}));
 #Select A random out peer
 OUT=${sendout_arr[j]};

 echo -e "\n 3.out------> "$OUT"\n";  grep $OUT $MY_T_DIR/peers | tail -7;

 echo -e "\n 3.in-------> "$IN"\n"; grep $IN $MY_T_DIR/peers | tail -7;

 $BOS rebalance --in $IN --out $OUT --in-target-outbound CAPACITY --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --avoid "$OUT/FEE_RATE>$LIMIT_FEE_RATE" --max-fee-rate $MAX_FEE_RATE --max-fee $MAX_FEE $AVOID;\
 date; sleep 1;
done

echo "Step 4 ... Increasing remote for channels we prefer to keep remote"
echo "Working with ${#forin_arr[@]} peers to increase inbound via ${#bringin_arr[@]} peers to decrease inbound"

for OUT in "${forin_arr[@]}"; do \
 j=$(($RANDOM % ${#bringin_arr[@]}));
 #Select A random in peer
 IN=${bringin_arr[j]};

 echo -e "\n 4.out------> "$OUT"\n";  grep $OUT $MY_T_DIR/peers | tail -7;

 echo -e "\n 4.in-------> "$IN"\n"; grep $IN $MY_T_DIR/peers | tail -7;

 $BOS rebalance --in $IN --out $OUT --out-target-inbound CAPACITY --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --avoid "$OUT/FEE_RATE>$LIMIT_FEE_RATE" --max-fee-rate $MAX_FEE_RATE --max-fee $MAX_FEE $AVOID;\
 date; sleep 1;
done

#This section is only applicaation if you have channel with LOOP. Remember to increase fees with LOOP

loop_count=`grep $LOOP $MY_T_DIR/peers | wc -l` 

if [ $loop_count -gt 0 ]
then 
 echo "Step 5 ... Reduce Remote for LOOP"
 MAX_FEE_RATE=$LOOP_MAX_FEE_RATE
 LIMIT_FEE_RATE=$LOOP_LIMIT_FEE_RATE

 IN=$LOOP
 echo -e "\n 5.in-------> "$IN"\n"; grep $IN $MY_T_DIR/peers | tail -7;

 $BOS rebalance --in $IN --in-target-outbound CAPACITY --avoid "FEE_RATE>$LIMIT_FEE_RATE/$IN" --max-fee-rate $MAX_FEE_RATE --max-fee $MAX_FEE $AVOID;
 date; sleep 1;
fi

#Cleanup
rm -rf $MY_T_DIR

#Tip Author
if [ $TIP -ne 0 ]
then
 echo "Thank you... $TIP"
 $BOS send 03c5528c628681aa17ab9e117aa3ee6f06c750dfb17df758ecabcd68f1567ad8c1 --amount $TIP --message "Thank you for rebalancing $MY_KEY"
fi
 
echo Final Sleep you can press ctrl-c
date; 
echo "========= SLEEP ========"
sleep 3600
