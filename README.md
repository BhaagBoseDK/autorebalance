# autorebalance
	
This script can be run continuously to attempt to create a balanced node or one can run it on-demand.

# Algo:

Collect a set "sendout set" of peers with outbouond > OUT_OVER_CAPACITY (these are channels which are sent to remote using --out). You can add a list of peers which need to be omitted here if you do not want to use them as --out peers.  

Collect a set "bringin_set" peers with outbound < IN_TARGET_OUTBOUND (these are depleted channels and need some minimal liquidity using --in). 

In Step 1 for every peer in bringin_set, a random out peer is selected from sendout_set and bos rebalance is performend to ensure at least IN_TARGET_OUTBOUND liquidity.

In Step 2 for every peer in sendout_set, a random in peer is selected from bringin_set and bos rebalance is performed to ensure outbound capacity as 50:50 on the out peer.

At the end of the process, your node would have minimal liquidty on all channels which is good for your ranking and routability. It will also ensure heavy outbound channels are balanced.

Please ensure IN_TARGET_OUTBOUND should be less than your entire node OUT_BOUND/CAPACITY. Recommended 20% (0.2) tends to work for most nodes but can be adjusted.

The script can be updated to suit your individual needs. Further optimisation can be built. Please send suggestion to author (or report via issue report).

# Usage:

Most nodes end up suffering from lack of liquidit on their local balace which leads to routing failure on their node as well as loss of reputation and reliability on the network, leading to their node being ignored on paths where there is liquidity.

This script attempts to keep a minimum local balance on most channels to ensure reasonbale routing. Coupled with liquidity driven fee policy (low fee on high local, high fee on low local) it can create a two way routing node and improve the node position within the network.

This script run continuously to attempt to create a balanced node. The main idea is to keep minimial liquidity on each channel to at least route some payments. The user is expected to customise the script with respect to fees and other parameters. These are available to edit on top of the script.  It can be executed in a TMUX session continuously as:

# Installation
```
cd ~
git clone https://github.com/BhaagBoseDK/autorebalance
```


The above will get the repository in ~/autorebalance directory
For updates do 

```
cd ~/autorebalance
git pull
```
You should customise the script to your individual needs. Read it at least once speicially the user configuration section.

Test it using

```
cd ~/autorebalance
. ./autorebalance.sh 
```
Then run continuously if you are comfortable.
	
```
while true; do . ~/autorebalance/autorebalance.sh; done
```  
  
Or, it can be executed as a daily cron job. BOS (Balance of Satoshi) needs to be installed Add the following in crontab to run regulary. Change path as appropriate

```
42 21 * * * ~/autorebalance/autorebalance.sh >> ~/autorebalance/autorebalance.log 2>&1
```

Change TIP=0 if you do not wish to tip the author.

You may have to configure myBOS variable if the script is unable to determine bos installation.

Author:  VS https://t.me/BhaagBoseDk 

Contact on telegram if there are issues running the script.

Change History:
```	
#0.0.1 - first version
#0.0.2 - Added Tip for fun
#0.0.3 - Handling various bos instllations
#0.0.4 - Improvement after bos 10.20.0
#0.1.0 - Reduced Sleep Time, minor varibale name change, other minor updates
#0.1.1 - Placeholder for customised rebalances; added Out->In rebalcne for heavy local;
         change to array from local file
         use of temporary in memory file system for working directories
         change to array from local file
#0.1.2 - use bos call to get MY_KEY
       - bugfix with temp directory to use PWD if temp area not created.
```
