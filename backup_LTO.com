#! /bin/tcsh -f
#
#        manage backing up stuff to the LTO tape drive                -James Holton 1-8-24
#
#
set path = ( $path /programs/beamline/ )

set dir    = ""
set stream = data
set tape   = 00001

set logprefix = "/data/log/LTO"
set devtape   = /dev/tape

set stream = ""
set tape   = ""

set BS = 512k
set BS = 8M

set maxtape = ""
set dtime = "+1:-7776000"

set not      = "default   "

foreach arg ( $* )
    set ARG = `echo $arg | awk '{print toupper($1)}'`
    set key = `echo $arg | awk -F "=" 'NF==2{print tolower($1)}'`
    set Val = `echo $arg | awk -F "=" 'NF==2{print $2}'`
    set VAL = `echo $Val | awk '{print toupper($1)}'`

    if(("$ARG" =~ NO*) || ("$ARG" =~ "-NO"*)) then
        set NO
        continue
    endif
    if("$arg" == "-noreadback") then
        echo "read-back step will be skipped"
        set NOREADBACK
        continue
    endif
    if("$arg" == "-regardless") then
        set not = ""
        continue
    endif
    if("$key" == "stream") then
        set stream = "$Val"
        echo "stream = $stream"
        continue
    endif
    if("$key" == "tape") then
        set tape = "$Val"
        set USER_tape = $tape
        echo "tape = $tape"
        continue
    endif
    if("$key" == "maxtape" || "$key" == "terabytes") then
        set maxtape = "$Val"
        echo "maxtape = $maxtape"
        continue
    endif
    if("$key" == "bs") then
        set BS = "$VAL"
        echo "blocksize = $BS"
        continue
    endif
    if("$key" == "device") then
        set devtape = "$Val"
        echo "devtape = $devtape"
        continue
    endif
    if("$key" == "tapedata") then
        set tapedata = "$Val"
        echo "tapedata = $tapedata"
        continue
    endif
    if("$key" == "dir") then
        set dir = ( $dir $Val )
        set user_dir = ( $dir )
        continue
    endif
    if("$key" == "logprefix" || "$key" == "logdir" || "$key" == "datalog") then
        set logprefix = "$Val"
        echo "logprefix = $logprefix"
        continue
    endif
    if("$arg" == "readback" || "$arg" == "-readback") then
        if($?NO) then
            set NOREADBACK
            unset NO
            continue
        endif
        set READBACK_ONLY
        continue
    endif
    if("$arg" == "justwrite" || "$arg" == "-justwrite") then
        if($?NO) then
            set JUST_WRITE
            unset NO
            continue
        endif
        set JUST_WRITE
        continue
    endif
    if("$stream" == maddata && "$arg" =~ [1-2][0-9][0-9][0-9]) then
#        set tape = "$arg"
#        continue
    endif
    if("$arg" =~ [0-9][0-9][0-9][0-9][0-9]) then
        set tape = "$arg"
        continue
    endif
    if(-d "$arg") then
        set dir = ( $dir $arg )
        set user_dir = ( $dir )
        continue
    endif
    if($?NO) then
        if("$not" == "default   ") set not = ""
        set not = ( $not $arg )
        continue
    endif
    unset NO
#    set stream = "$arg"
end


if( ! $?USER_tape && ( "$stream" != "" || "$tape" == "" ) ) then
    tail -n 100 ${logprefix}/backup_LTO_${stream}_?????_tapeup_timing*.log |\
    awk -v stream=$stream '/^==> /{\
      tape=substr($2,index($2,"_"stream"_")+length(stream)+2,5)}\
      /No space left on device/{printf("%05d\n",tape+1);}' |\
    sort -gr | head -1 >! nexttape.txt
    set tape = `cat nexttape.txt`
    rm -f nexttape.txt
    echo "next tape will be $stream $tape"
endif
if("$stream" == "" || "$tape" == "") then
    goto check_tape
endif
return_from_checktape:

test -t 1
if($status) then
    set AUTO
endif

if(! $?tapedata) then
    if("$stream" != "") then
        set tapedata = /cache/tapedata_${stream}
    else
        set tapedata = /cache/tapedata
    endif
endif

if($?READBACK_ONLY) goto readback
if( $?JUST_WRITE) then
    if(-e $tapedata) then
        goto write2tape
    endif
    echo "SORRY, no $tapedata , need to re-create it..."
endif

# default to exclude common undesirables
if("$not" == "default   ") then
    set not = "\.imx_ \.dkx_ mtz2various_TMP \.adxv_beam_center tempfile sent_home _temp align /data/homebak MiscScans scan\.inf scan\.efs on\.jpg beam\.jpg diff\.jpg in\.jpg diff.\.jpg sqr.\.jpg thresh\.jpg blob\.jpg over\.jpg marked\.jpg nih_\.jpg ftp.rcsb.org \/FRAME \/GAIN \/ABS \/ABSORP \/BKGINIT \/BKGPIX \/BLANK \/DECAY \/MODPIX -CORRECTIONS \/TILEIMAGE\.img"
    if("$stream" =~ *home*) then
        set not = "${not} /home/share/scores /home/share/log/ /home/maddata /home/scores.xfs /home/data3/ /home/sqshfs/ laptop_restore cctbx ftp.wwpdb.org cache /.mozilla/firefox \.pickle; \.refl; /home/jamesh/"
    endif
endif

# create exclusion definitions
set not = `echo " $not " | awk 'BEGIN{RS=" "} NF==1{printf "%s|", $1}'`
set not = `echo $not | awk '{gsub(";","$");gsub("\\|\\|","|");print substr($1,1,length($1)-1)}'`

# default to just images 
set onlyfind = ""
if("$stream" =~ *data*) set onlyfind = "jpg jpeg img scan cbf bip [0-9][0-9][0-9][0-9][0-9].txt"
if("$stream" =~ *data[234]*) set onlyfind = ""


if ("$not" == "") set not = "\n "

set onlyfind = `echo " $onlyfind " | awk 'BEGIN{RS=" "} NF==1{printf "%s|", $1}'`
set onlyfind = `echo "$onlyfind" | awk '{print substr($1,1,length($1)-1)}'`



if(-e ${logprefix}/backup_LTO_${stream}_tarup_${tape}.log) then
    set n = 1
    while (-e ${logprefix}/backup_LTO_${stream}_tarup_${tape}_${n}.log)
        @ n = ( $n + 1 )
    end
    mv ${logprefix}/backup_LTO_${stream}_tarup_${tape}.log ${logprefix}/backup_LTO_${stream}_tarup_${tape}_${n}.log
endif
touch ${logprefix}/backup_LTO_${stream}_tarup_${tape}.log

if("$tape" == "") set tape = "\t"
set recent_tapes = `ls -1rt ${logprefix}/backup_LTO_${stream}_[0-9][0-9][0-9][0-9][0-9].log | egrep -v "timing|tarup|tarlist|2btared" | egrep -v $tape | tail -20`
echo "old tapes: $recent_tapes"

#set tooold = `tail -n 1 $recent_tapes[4] | awk '{print $1}'`
#set tooold = `awk 'NR==1 || $1<tooold{tooold=$1} END{print tooold}' $recent_tapes` 
#set tooold = `head -n 1000 $recent_tapes[3] | tail -n 1 | awk '{print $1;exit}'`
set tooold = 0
if($#recent_tapes >= 3) then
    set tooold = `awk '$1+0>max+0{max=$1} END{print max}' $recent_tapes[1] $recent_tapes[2] $recent_tapes[3]`
endif
if("$tooold" == "") set tooold = 0
set tooold_date = `echo "puts [clock format $tooold]" | tclsh`
touch --date="$tooold_date" tooold
echo "disregarding files older than $tooold_date"

if("$dir" == "") then
    set BAD = "no directory specified"
    goto exit
endif

echo "finding files on $dir"
echo "with pattern: $onlyfind"
echo "and filtering out: $not"
echo "delta-T: $dtime"
find ${dir} -mount \( -type f -o -type l \) -cnewer tooold -printf '%T@ %s ONDISK: %p\n' |\
tee ondisk.log |\
egrep "$onlyfind" |\
egrep -v "$not" |\
cat $recent_tapes - |\
awk -v tooold=$tooold '$1>tooold' |\
awk -v dtime=$dtime 'BEGIN{split(dtime,w,":");late=w[1]+0;early=w[2]+0;\
    if(early>late){early=late;late=w[2]+0}}\
   /ONDISK:/ && NF!=4{next}\
  {time=ptime=int($1);file=$NF;cmp=$NF;gsub("^/|.gz$","",cmp)}\
  ! /ONDISK:/{++seen[cmp];timeof[cmp,seen[cmp]]=time;next}\
    /ONDISK:/{bak=1;for(i=1;i<=seen[cmp];++i){\
       otime=timeof[cmp,i];dt=time-otime;\
       if(early<=dt && dt<=late)bak=0;\
       };\
    if(bak) print time,$2,file}' |\
tee 2btared.log |\
awk 'NR%123==0{printf "%d\r",NR}'
sort -n 2btared.log >! ${logprefix}/backup_LTO_${stream}_2btared_${tape}.log


set Gbytes_togo = `awk '{sum+=$2} END{print sum/1024^3}' ${logprefix}/backup_LTO_${stream}_2btared_${tape}.log`

echo "$Gbytes_togo GB need to be backed up"



set n = 1
while (-e ${logprefix}/backup_LTO_${stream}_${tape}_tarup_timing${n}.log)
    @ n = ( $n + 1 )
end


echo "writing data to tape cache..."
rm -f $tapedata
set terabytes = `df -k /cache/ | tail -1 | awk '{print $4/1024^3*0.95}'`
echo "$terabytes TB available on /cache/ "
if("$maxtape" != "") set terabytes = "$maxtape"

cat ${logprefix}/backup_LTO_${stream}_2btared_${tape}.log |\
awk -v tb=$terabytes '{sum+=$2} sum/1024^4<tb{print substr($0,index($0,$3))}' |\
( tar cvbTf 2048 - - | ( dd obs=${BS} of=$tapedata |& log_timestamp.tcl > ${logprefix}/backup_LTO_${stream}_${tape}_tarup_timing${n}.log ) ) |&\
tee -a ${logprefix}/backup_LTO_${stream}_tarup_${tape}.log |\
awk '{printf("%s%20s\r",$0,"")}' 
if($status) then
    set BAD = "tar error"
    goto exit
endif
echo ""


write2tape:

if(! $?n) set n = 1
while (-e ${logprefix}/backup_LTO_${stream}_${tape}_tapeup_timing${n}.log)
    @ n = ( $n + 1 )
end

set tape_in = `mt -f $devtape status |& tail -1 | awk '{print ( /ONLINE/ )}'`
if (! $tape_in) then
    echo "loading the tape..."
    mt -f $devtape load
    set tape_in = `mt -f $devtape status |& tail -1 | awk '{print ( /ONLINE/ )}'`
    if (! $tape_in) then
        echo "please insert a tape..."
        echo -n "-> "
            if($?AUTO) then
            echo "Y"
            set test = "Y"
        else
            set test = ( $< )
        endif
        if("$test" =~ [nN]* ) then
            goto exit
            endif
    endif
endif

check_cm:
# check/record the cartridge memory
set cm_name = "831_${stream}_${tape}"
if("$stream" == "alsenable") set cm_name = "${stream}_${tape}"
echo "accessing cartridge memory..."
( sg_raw -o - -r 1024 -t 60 -v $devtape 8c 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 > ! /dev/shm/raw.bin ) >& /dev/null
set noglob
set stuff = `strings /dev/shm/raw.bin `
echo "tape info: $stuff"
set tapeSN = `echo "$stuff" | awk '{gsub(/[*?]/,"");print $NF}'`
unset noglob
set cmlog_info = `grep "$tapeSN" /data/log/LTO/cartridge_memory.log | awk '{print $1}'`
if($#cmlog_info != 0) then
    echo "tape previously used as $cmlog_info"
else
    echo "no entry in /data/log/LTO/cartridge_memory.log"
    echo "claiming tape for $cm_name"
    /usr/src/lto-cm/lto-cm -f $devtape -w "$cm_name"
    sleep 1
    ( sg_raw -o - -r 1024 -t 60 -v $devtape 8c 00 00 00 00 00 00 00 00 00 00 00 04 00 00 00 > ! /dev/shm/raw.bin ) >& /dev/null
    set noglob
    set stuff = `strings /dev/shm/raw.bin `
    echo "tape info: $stuff"
    echo "${cm_name}   $stuff" | tee -a /data/log/LTO/cartridge_memory.log
    unset noglob
    set cmlog_info = "$cm_name"
endif
if("$cmlog_info" != "$cm_name") then
    set BAD = "trying to over-write previous tape: $cmlog_info"
    mt -f $devtape eject
    page.com Holton "change LTO6 tape"
    echo "hit <Enter> to confirm new tape:"
    set in = ( $< )
    goto check_cm
endif


echo "rewinding the tape..."
mt -f $devtape rewind
#echo "moving to end of data on tape..."
#mt -f $devtape fsfm
if(-s ${logprefix}/backup_LTO_${stream}_${tape}.log) then
    set Gbytes = `awk '{sum+=$2} END{print sum/1024^3}' ${logprefix}/backup_LTO_${stream}_${tape}.log`
    echo "$Gbytes GB already written to tape will be erased"
    set GB = `mt -f $devtape tell | awk '{print $3*8/1024}'`
    echo "$GB GB into the tape now."
    #echo "is this the right place? "
    echo -n "OK? -> "
    if($?AUTO) then
        echo "Y"
        set test = "Y"
    else
        set test = ( $< )
    endif
    if("$test" =~ [nN]* ) then
        goto exit
    endif
endif
echo "making sure disk verify is not running..."
tw_cli /c0/u0 stop verify
sleep 1
tw_cli /c0/u1 stop verify
sleep 3
echo "making sure any file transfers are stopped..."
killall -STOP dd
killall -STOP tar
killall -STOP rsync
killall -STOP python
wall "backup starting. DO NOT RUN JOBS UNTIL FURTHER NOTICE\!\!\! "
sleep 1

swapoff -a
echo 7 | tee /proc/sys/vm/zone_reclaim_mode
echo 3 | tee /proc/sys/vm/drop_caches
echo 1 | tee /proc/sys/vm/oom_dump_tasks
echo 1 | tee /proc/sys/vm/compact_memory
sleep 5
echo 0 | tee /proc/sys/vm/zone_reclaim_mode

mt -f $devtape status

unset PROBLEM

echo "retensioning tape..."
mt -f $devtape rewind
set goal = 1
rm -f dt_vs_pos.txt > /dev/null
set t0 = `msdate.com | awk '{print $NF}'`
set t = 0
while ( $goal < 1000000 )
  set t1 = `msdate.com | awk '{print $NF}'`
  mt -f $devtape seek $goal
  if ( $status ) break
  set pos = `mt -f $devtape tell`
  set posint = `echo $pos | awk '/At block/{print $NF+0}'`
  if( "$posint" != "$goal" ) break
  set t = `msdate.com $t0 | awk '{print int($NF)}'`
  set dt = `msdate.com $t1 | awk '{print $NF}'`
  echo "$dt $pos" | tee -a dt_vs_pos.txt
  @ goal = ( $goal * 2 )
end
mt -f $devtape rewind

echo "cacheing data..."
dd if=$tapedata bs=100M of=/dev/null count=1024
mt -f $devtape status
echo "priming tape..."
dd if=$tapedata bs=${BS} of=$devtape  count=10240
mt -f $devtape status
echo "rewinding tape"
mt -f $devtape rewind
mt -f $devtape status

echo "writing data to tape..."
dd if=$tapedata obs=${BS} of=$devtape  |& log_timestamp.tcl > ${logprefix}/backup_LTO_${stream}_${tape}_tapeup_timing${n}.log 

if($status) set PROBLEM

# re-start any transfers...
killall -CONT dd  >& /dev/null
killall -CONT tar >& /dev/null
killall -CONT rsync >& /dev/null
killall -CONT python >& /dev/null
wall "backup done."

if($?PROBLEM) then
    set BAD = "tape error"
    grep "No space left" ${logprefix}/backup_LTO_${stream}_${tape}_tapeup_timing${n}.log
    if(! $status) then
        unset BAD
        goto readback
    endif
    echo "check ${logprefix}/backup_LTO_${stream}_${tape}_tapeup_timing${n}.log"
    tail ${logprefix}/backup_LTO_${stream}_${tape}_tapeup_timing${n}.log
    goto exit
endif

cat ${logprefix}/backup_LTO_${stream}_${tape}_tapeup_timing${n}.log |\
 awk '/records out/{print $8,$9}' | awk '{gsub("+"," "); print}' |\
 awk -v BS=$BS '{mb=$2*BS;dt=$1-lastt;if(dt==0)dt=1;print $1,(mb-lastmb)/dt,mb; lastt=$1;lastmb=mb}' |\
cat >! ${logprefix}/backup_LTO_${stream}_${tape}_tapeup_timing_plotme.log


readback:
if($?NOREADBACK) goto rewind
echo "reading back the tape..."
foreach n ( 1   ) 

if(-e ${logprefix}/backup_LTO_${stream}_${tape}_tarlist_rb${n}.log) then
    mv ${logprefix}/backup_LTO_${stream}_${tape}_tarlist_rb${n}.log ${logprefix}/backup_LTO_${stream}_${tape}_tarlist_rb${n}_last.log
endif

mt -f $devtape rewind
mt -f $devtape rewind
( setenv TZ UTC ; dd obs=${BS} if=$devtape  ibs=${BS} |\
tar tivf - --utc --full-time >&! ${logprefix}/backup_LTO_${stream}_${tape}_tarlist_rb${n}.log )|&\
log_timestamp.tcl >&! ${logprefix}/backup_LTO_${stream}_${tape}_timing_rb${n}.log

cat ${logprefix}/backup_LTO_${stream}_${tape}_timing_rb${n}.log |\
 awk '/records out/{print $8,$9}' | awk '{gsub("+"," "); print}' |\
 awk -v BS=$BS '{mb=$2*BS;dt=$1-lastt;if(dt==0)dt=1;print $1,(mb-lastmb)/dt,mb; lastt=$1;lastmb=mb}' |\
cat >! ${logprefix}/backup_LTO_${stream}_${tape}_tarlist_timing${n}.log


cat ${logprefix}/backup_LTO_${stream}_${tape}_tarlist_rb${n}.log |\
awk '! /^tar: /' |\
awk '{print "set epoch [clock scan \""$4,$5,"UTC\"]";\
      gsub("[\"\\[\\]\\$]","\\\\&");\
      print "puts \"$epoch "$3" [clock format $epoch -format \"%a %b %d %T %Z %Y\"] /"$6"\""}' |\
tclsh |\
awk 'last!=""{print last} {last=$0}' |\
cat >&! ${logprefix}/backup_LTO_${stream}_${tape}.log




# check that this is consistent with expectations
rm -f /tmp/puton$$.txt /tmp/gotback$$.txt >& /dev/null

cat ${logprefix}/backup_LTO_${stream}_${tape}.log |\
awk '! ( /^tar/ || /^dd/ || /records in$/ || /records out$/ ){\
        gsub(" /"," ");print $NF}' |\
cat > ! /tmp/gotback$$.txt
set gotback = `cat /tmp/gotback$$.txt | wc -l`
cat ${logprefix}/backup_LTO_${stream}_tarup_${tape}.log |\
awk '! ( /^tar/ || /^dd/ || /records in$/ || /records out$/ ){\
        gsub("^/","");print $NF}' |\
cat >! /tmp/puton$$.txt
set puton = `cat /tmp/puton$$.txt | wc -l | awk '$1+0>0{print $1-1}'`

if("$puton" != "$gotback") then
    echo "WARNING: put on $puton files, but got back $gotback"
endif

end
rm -f /tmp/puton$$.txt /tmp/gotback$$.txt



set Gbytes = `awk '{sum+=$2} END{print sum/1024^3}' ${logprefix}/backup_LTO_${stream}_${tape}.log`
set files  = `cat ${logprefix}/backup_LTO_${stream}_${tape}.log | wc -l`

echo "tape $stream #$tape contains:"
echo "$Gbytes GB"
echo "$files files"

rewind:
echo ""
echo "rewinding the tape..."
mt -f $devtape eject

exit:
if($?BAD) then
    echo "ERROR: $BAD"
    exit 9
endif

exit








check_tape:

echo "checking tape..."
rm -f firstfiles.txt
mt -f $devtape rewind
if($status) then
    set BAD = "no tape! "
    goto exit
endif

set count = `echo $BS 1e9 | awk '$1~/k/{$1*=1000} $1~/M/{$1*=1e6} {print int($2/$1)}'`
( setenv TZ UTC ; dd if=$devtape  ibs=${BS} count=$count | tar tvf - >! firstfiles.txt ) >& /dev/null
mt -f $devtape rewind &

set lines = `cat firstfiles.txt | wc -l | awk '{print $1-1}'`
if($lines < 2) then
    echo "new tape."
    if($?tarlist) then
        set tape = `echo $tape | awk '{n=length($1);printf "%0"n"d\n", $1+1}'`
    endif
    set fulltape = 0
    goto new_tape
endif
set tapesum = `head -$lines firstfiles.txt | md5sum`

set tarlist
foreach tarlist ( `ls -1t ${logprefix}/backup_LTO_*${stream}*tarlist*` )

    set logsum = `head -$lines $tarlist | md5sum`
    if("$logsum" == "$tapesum") break
    set tarlist = ""

end

if("$tarlist" == "") then
    foreach tarlist ( `ls -1t ${logprefix}/backup_LTO_*tarlist*` )

        set logsum = `head -$lines $tarlist | md5sum`
        if("$logsum" == "$tapesum") break
        set tarlist = ""

    end
endif

if("$tarlist" == "" && $?READBACK_ONLY) then
    set fulltape = 0
    goto new_tape
endif

if("$tarlist" == "") then
    set BAD = "unknown tape! "
    cat firstfiles.txt
    goto exit
endif

echo "this tape matches: $tarlist"
set fulltape = `tail -2 $tarlist | grep -i error | wc -l`

set stream = `echo $tarlist | awk -F "[_]" '{for(i=1;i<=NF;++i) print $i}' | awk '/LTO/{getline;print}'`
set tape   = `echo $tarlist | awk -F "[_]" '{for(i=1;i<=NF;++i) print $i}' | awk '/LTO/{++p} p && $1+0>0{print}'`
set dir    = `head -1 firstfiles.txt | awk '{print $6}' | awk -F "[/]" '{print $1"/"}'`

if($?user_dir) then
    set dir = ( $user_dir )
endif

if(! -e "$dir" && -e "/"$dir) set dir = "/"$dir
if(! -e "$dir" && "$stream" == "maddata") then
    cd /data4/maddata/
endif
if(! -e "$dir") then
    set BAD = "cannot find directory: $dir"
    goto exit
endif

new_tape:

cat << EOF
set stream = $stream
set tape   = $tape
set dir    = $dir
set logprefix = $logprefix
EOF

if (-e ${logprefix}/backup_LTO_${stream}_${tape}.log) then
    set Gbytes = `awk '{sum+=$2} END{print sum/1024^3}' ${logprefix}/backup_LTO_${stream}_${tape}.log`
    set files  = `cat ${logprefix}/backup_LTO_${stream}_${tape}.log | wc -l`

    echo "tape $stream #$tape contains:"
    echo "$Gbytes GB"
    echo "$files files"
else
    echo "new stream"
endif

wait
if($fulltape) then
    echo "this tape is full. "
    mt -f $devtape eject
    echo "please put in a new tape for this stream:"
    echo -n "-> "
    set in = ( $< )
    goto check_tape
else
    mt -f $devtape rewind
endif


goto return_from_checktape





uncompressed LTO4 tape contains 781862305792 bytes.







set BS = 8M
ls -1rt ${logprefix}/backup_LTO_*_timing*.log | grep -v plotme | tee timelogs.txt

foreach timelog ( `cat timelogs.txt` )

set base = `basename $timelog .log`
set plotme = ${logprefix}/${base}_plotme.log

if(-e $plotme) then
    continue
    echo "WARNING"
endif

echo "making $plotme"

cat $timelog |\
 awk '/records out/{print $8,$9,$7}' |\
  awk '{gsub("+"," "); print}' |\
 awk -v BS=$BS '{mb=$2*BS;dt=$1-lastt;if(dt==0)dt=1;\
     print $1,(mb-lastmb)/dt,mb,"     ",$NF;\
     lastt=$1;lastmb=mb}' |\
cat >! $plotme

end


~jamesh/archiving/maintain_tapecache.com stream=alsenable dir=/alsenable/ dirhost=petabyte cache=/filecache/alsenable_local nowrite nodate &


data3:
anonymous/pub/tarballs|CentOS|Windoze_backups|data3/maddata/2004.sqshfs|data3/data2/scores.xfs|data3/Windoze_backups/Holton_laptop_win7.bin|data3/olddata3/scores_Nov08.xfs|data3/Windoze_backups/archive_image.bin|data3/Windoze_backups/HoltonPC_Backup.bkf




