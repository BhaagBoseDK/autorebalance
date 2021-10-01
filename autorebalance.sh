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
# ------------------------------------------------------------------------------------------------
#

script_ver=0.1.0

min_bos_ver=10.20.0

# Change These Parameters as per your requirements

#If you DO NOT wish to tip 1 sat to author each time you run this script make this value 0. If you wish to increase the tip, change to whatever you want. 
TIP=1

# your public key
MY_KEY=03c5528c628681aa17ab9e117aa3ee6f06c750dfb17df758ecabcd68f1567ad8c1
# Max_Fee is kept as high since we will control the rebalance with fee-rate. Change if reuired.
MAX_FEE=50000

# Max Fee you want to pay for rebalance.
MAX_FEE_RATE=299

# Fee used to avoid expensive channels into you.
LIMIT_FEE_RATE=299

#Consider these channels for decreasing local balance (move to remote) when outbound is above this limit
OUT_OVER_CAPACITY=0.6

# Target rebalance to this capacity of Local. Keep this below 0.5 (50%)
IN_TARGET_OUTBOUND=0.2

#If you run bos in a specific manner or have alias defined for bos, type the same here and uncomment the line (replace #myBOS= by myBOS= and provide your bos path)
#myBOS="your installation specific way to run bos"

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

# Peers to be omitted from outbound remabalancing. Add to --omit pubkey --omit pubkey syntax. If not specified all peers are considered
OMIT=" "

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

echo "Ensure Some Local if channel balance is < $IN_TARGET_OUTBOUND"

#Get peers with high outbound

$BOS peers --no-color --complete --sort inbound_liquidity --filter "OUTBOUND_LIQUIDITY>(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$OUT_OVER_CAPACITY" $OMIT \
| grep public_key: | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}' > ./sendout_tmp 

#Get all low outbound channels to rebalance
$BOS peers --no-color --complete --filter "OUTBOUND_LIQUIDITY<(OUTBOUND_LIQUIDITY+INBOUND_LIQUIDITY)*$IN_TARGET_OUTBOUND" --sort outbound_liquidity | grep public_key: | awk -F : '{gsub(/^[ \t]+/, "", $2);print $2}' > ./bringin ;

#Get unique list of nodes which can be used for rebalance (must have larger outbound)
sendout_arr=(`cat ./sendout_tmp`)

if [ ${#sendout_arr[@]} -eq 0 ] 
then
 echo "Error -1 : No outbound peers available for rebalance. Consider lowering OUT_OVER_CAPACITY from "$OUT_OVER_CAPACITY
 exit -1
fi

# Avoid the nodes which are alreayd depleted from rebalancing
AVOID=" "
for i in `cat ./bringin`
 do AVOID=" --avoid $MY_KEY/$i $AVOID";
 done

#echo $AVOID

# Rebalance with a random outbound node 
for i in `cat ./bringin`; do \
 j=$(($RANDOM % ${#sendout_arr[@]}));
 #Select A random out peer
 OUT=${sendout_arr[j]};

 echo -e "\n out------> "$OUT"\n"; 
 echo -e "\n in-------> "$i"\n";

 $BOS rebalance --in $i --out $OUT --in-target-outbound CAPACITY*$IN_TARGET_OUTBOUND --avoid "FEE_RATE>$LIMIT_FEE_RATE/$i" --max-fee-rate $MAX_FEE_RATE --max-fee $MAX_FEE $AVOID;\
 date; sleep 1;\
done

#Place for other rebalances, custom rebalances


#Cleanup
rm -f ./bringin ./sendout_tmp

#Tip Author
if [ $TIP -ne 0 ]
then
 echo "Thank you... $TIP"
 $BOS send 03c5528c628681aa17ab9e117aa3ee6f06c750dfb17df758ecabcd68f1567ad8c1 --amount $TIP --message "Thank you from $MY_KEY"
fi
 
echo Final Sleep
date; 
echo "========= SLEEP ========"
# Remove # from the following line to sleep 10 minutes if you are running in a while loop.
#sleep 600
