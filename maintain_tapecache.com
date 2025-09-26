#! /bin/tcsh -f
#
#   scan remote filesystem and update local cache
#   trigger tape backup when we have enough data
#   clear the cache when it stats to get full                 - James Holton 9-26-25
#
#
set stream = data
set dir    = /data
set dirhost = ""

set cache = /filecache

# in terabytes
set tapemax = 2.4
set tapemax = 6

foreach arg ( $* )
    set key = `echo $arg | awk -F "=" '{print $1}'`
    set val = `echo $arg | awk -F "=" '{print $2}'`
    if("$key" == "stream") set stream = "$val"
    if("$key" == "dir") set dir = "$val"
    if("$key" == "dirhost") set dirhost = "$val"
    if("$key" == "cache") set cache = "$val"
    if("$key" == "tapemax") set tapemax = "$val"
    if("$key" == "nowrite") set NOWRITE
    if("$key" == "nodate") set NODATE
end

if( "$dirhost" == "" ) then
    set dirhost = `df $dir | awk -F ":" '{print $1}' | tail -n 1`
endif
echo "$dir is hosted by $dirhost"

newtape:
tail -n 100 /data/log/LTO/backup_LTO_${stream}_?????_tapeup_timing*.log |\
awk -v stream=$stream '/^==> /{\
  tape=substr($2,index($2,"_"stream"_")+length(stream)+2,5)}\
  /No space left on device/{printf("%05d\n",tape+1);}' |\
sort -gr | head -1 >! nexttape.txt
set tape = `cat nexttape.txt`
rm -f nexttape.txt
echo "next tape will be $stream $tape"
if("$tape" == "") then
    set BAD = "cannot determine next tape number "
    goto exit
endif


set not = "\.imx_ \.dkx_ mtz2various_TMP \.adxv_beam_center tempfile sent_home _temp align /data/homebak MiscScans scan\.inf scan\.efs on\.jpg beam\.jpg diff\.jpg in\.jpg diff.\.jpg sqr.\.jpg thresh\.jpg blob\.jpg over\.jpg marked\.jpg nih_\.jpg ftp.rcsb.org dark_current programs dialsdev OLD_RUNS \/FRAME \/GAIN \/ABS \/ABSORP \/BKGINIT \/BKGPIX \/BLANK \/DECAY \/MODPIX -CORRECTIONS"

set onlyfind = "jpg jpeg img cbf scan bip [0-9][0-9][0-9][0-9][0-9].txt"
set onlyfind = `echo " $onlyfind " | awk 'BEGIN{RS=" "} NF==1{printf "%s|", $1}'`

set onlyfind = `echo "$onlyfind" | awk '{print substr($1,1,length($1)-1)}'`

set not = `echo " $not " | awk 'BEGIN{RS=" "} NF==1{printf "%s|", $1}'`
set not = `echo $not | awk '{print substr($1,1,length($1)-1)}'`


while ( 1 )


set recent_tapes = `ls -1rt /data/log/LTO/backup_LTO_${stream}_[0-9][0-9][0-9][0-9][0-9].log | egrep -v "timing|tarup|tarlist|2btared" | egrep -v $tape | tail -10`
echo "old tapes: $recent_tapes"

head -n 1000 /data/log/LTO/backup_LTO_${stream}_[0-9][0-9][0-9][0-9][0-9].log >! tape_file_date_samples.txt
tail -n 1000 /data/log/LTO/backup_LTO_${stream}_[0-9][0-9][0-9][0-9][0-9].log >> tape_file_date_samples.txt
set tooold = `sort -g tape_file_date_samples.txt | awk 'NF>5' | tail -5000 | head -n 1 | awk '{print $1;exit}'`
rm -f tape_file_date_samples.txt
if($?NODATE) set tooold = `date | awk '{print "puts [clock scan \"Jan 1 00:00:00 "$NF"\"]"}' | tclsh`
set tooold_date = `echo "puts [clock format $tooold]" | tclsh`
touch --date="$tooold_date" tooold
echo "disregarding files older than $tooold_date"


find ${cache}/ -mount \( -type f -o -type l \) -printf '%T@ %s %TY /%P\n' |\
awk -v dir=$dir '$NF ~ "^"dir{print;\
  n=split($NF,w,"/");\
  if(w[3]~/^BL[1-8][1-3][1-3]/ && w[4]=="data"){\
    w[4]=$3;\
    f="";for(i=2;i<=n;++i){f=f"/"w[i]};\
    print $1,$2,"data",f}}' |\
cat >! already_got.txt

set backhost = `hostname -s`
set sshcmd = 'ssh -oBatchMode=yes -oConnectTimeout=1 '$dirhost' "tcsh"'
if("$dirhost" == "$backhost") set sshcmd = tcsh
set mount = "-mount"
if("$stream" == "alsenable") set mount = ""

cat << EOF >! rcmd.txt
touch --date='$tooold_date' tooold
find ${dir} $mount \( -type f -o -type l \) -cnewer tooold -printf '%T@ %s ONDISK: %p\n' 
EOF

echo "finding files on $dir"
echo "with pattern: $onlyfind"
echo "and filtering out: $not"
cat rcmd.txt | $sshcmd |\
tee ondisk.txt |\
egrep "$onlyfind" |\
egrep -v "$not" |\
cat $recent_tapes already_got.txt - |\
awk -v tooold=$tooold '$1>tooold' |\
awk -v nd=$?NODATE '/ONDISK:/ && NF!=4{next}\
  {time=ptime=int($1);file=$NF;cmp=$NF;gsub("^/|.gz$","",cmp)}\
  NF>4{ttime[cmp]=time}\
  nd{otime[cmp]=time;time=0}\
  ! /ONDISK:/{++seen[time,cmp];next}\
    /ONDISK:/ && ! seen[time,cmp]{\
       if( time==0)ptime=ttime[cmp]+0;\
       if(ptime==0)ptime=otime[cmp]+0;\
       print ptime,$2,file}' |\
tee 2bxferred.log |\
awk 'NR%123==0{printf "%d\r",NR}'

set terabytes = `df -k $cache | tail -1 | awk '{print $4/1024/1024/1024}'`
echo "$terabytes TB available on $cache "


if("$dirhost" == "$backhost") then
    sort -n 2bxferred.log |\
    awk -v maxall=$terabytes '{print;sum+=$2} sum/1024^4>maxall{exit}' |\
    awk '{print $NF}' |\
    tar cTf - - | tar xvCf $cache -
else
  if( $?compress ) then
    nc -d -l 12345 | pigz -d | tar xvCf $cache - | awk '{printf("%s                   \r",$0)}' &
    sleep 1

    sort -n 2bxferred.log |\
    awk -v maxall=$terabytes '{print;sum+=$2} sum/1024^4>maxall{exit}' |\
    awk '{print $NF}' |\
    ssh $dirhost "tar cTf - - | pigz --fast | nc $backhost 12345"
  else
    nc -d -l 12345 | dd bs=1M | tar xvCf $cache - | awk '{printf("%s                   \r",$0)}' &
    sleep 1

    sort -n 2bxferred.log |\
    awk -v maxall=$terabytes '{print;sum+=$2} sum/1024^4>maxall{exit}' |\
    awk '{print $NF}' |\
    ssh $dirhost "tar cTf - - | nc $backhost 12345"
  endif
endif

#rsync -avx ${cache}/data olddata2::olddata/

# see how much will go onto next tape
awk '{$3="ONDISK:";print}' already_got.txt |\
egrep "$onlyfind" |\
egrep -v "$not" |\
cat $recent_tapes - |\
awk -v tooold=$tooold '$1>tooold' |\
awk -v nd=$?NODATE '/ONDISK:/ && NF!=4{next}\
  {time=ptime=int($1);file=$NF;cmp=$NF;gsub("^/|.gz$","",cmp)}\
  NF>4{ttime[cmp]=time}\
  nd{otime[cmp]=time;time=0}\
  ! /ONDISK:/{++seen[time,cmp];next}\
    /ONDISK:/ && ! seen[time,cmp]{\
       if( time==0)ptime=ttime[cmp]+0;\
       if(ptime==0)ptime=otime[cmp]+0;\
       print ptime,$2,file}' |\
tee 2btaped.log |\
awk 'NR%123==0{printf "%d\r",NR}'


# check if there is enough data for a tape
set terabytes = `df -k $cache | tail -1 | awk '{print $3/1024/1024/1024}'`
echo "$terabytes TB on $cache "
set terabytes = `du -k ${cache}/$dir | tail -1 | awk '{print $1/1024/1024/1024}'`
echo "$terabytes TB in ${cache}/$dir "
set terabytes = `awk '{sum+=$2} END{print sum/1024**4}' 2btaped.log`
echo "$terabytes TB to be taped "
set test = `echo $terabytes $tapemax | awk '{print ($1>$2)}'`
if(! $test) then
    echo "not enough to write a tape"
else
    setenv AUTO
    mt load
    set pwd = `pwd`
    cd /cache/
    set subdir = `echo $dir | awk '{gsub("^/","");print}'`
    if(! -l $subdir) ln -sf ${cache}/${subdir} ./$subdir
    if( $?NOWRITE ) then
        echo "ready to write tape."
        exit
    endif
    backup_LTO.com ${subdir}/ stream=$stream $tape
    
    # check if the tape actually filled up
    set test = `grep "No space left" /data/log/LTO/backup_LTO_${stream}_${tape}_tapeup_timing*.log | wc -l`
    if(! $test) then
        set BAD = "tape size prediction failure."
        set log = `ls -1rt /data/log/LTO/backup_LTO_${stream}_${tape}_tapeup_timing*.log | tail -n 1`
        grep -i error $log
        goto exit
    endif

    unset noglob
    set tapelabel = "8.3.1 $stream"
    if("$stream" == "alsenable") set tapelabel = $stream
    ~/tape_daterange.com /data/log/LTO/backup_LTO_${stream}_${tape}.log | tee tape_daterange.txt
    awk '{print "puts [clock format [clock scan \""$0"\"] -format \"%m %d %y\"]"}' tape_daterange.txt |\
    tclsh >! tempfile.txt
    set tape_daterange = `awk 'NR==2{print $1+0"-"$2+0"-"$3,"to"} NR==5{print $1+0"-"$2+0"-"$3}' tempfile.txt`
    rm -f tempfile.txt
    mail -s "change tape" jmholton@lbl.gov << EOF
please change tape in archive3.  Write protect.  Label as:
$tapelabel #$tape
$tape_daterange
EOF

    # now clean up?
    cd /local
    echo "checking all backed-up files"
#    cat /data/log/LTO/backup_LTO_${stream}_?????.log |\
#    awk -v cache=$cache '{print "rm -f",cache $NF}' |\
#    cat >! ontape.txt

    tail -n 100 /data/log/LTO/backup_LTO_${stream}_?????_tapeup_timing*.log |\
    awk -v stream=$stream '/^==> /{\
      tape=substr($2,index($2,"_"stream"_")+length(stream)+2,5)}\
     /No space left on device/{printf("%s %05d\n",stream,tape);}' |\
    sort -g >! fulltapes.txt
    set fulltapes = `awk '{printf("/data/log/LTO/backup_LTO_%s_%s.log\n",$1,$2)}' fulltapes.txt | tail -n 12 | head -n 10`

    echo "checking last 11 full tapes"
    cat $fulltapes |\
    awk -v cache=$cache '{print "rm -f",cache $NF}' |\
    cat >! ontape.txt

    echo "checking all files in cache"
    find ${cache}/ -type f >! incache.txt

    echo "looking for files that can now be cleared from cache."
    cat incache.txt ontape.txt |\
    awk '{gsub("//","/");print}' |\
    awk '{file=$NF} NF==1{file=$1}\
         {cmp=file;gsub("^/|.gz$","",cmp);}\
         NF==1{++incache[cmp];next}\
         /^rm/ && incache[cmp]{print}' |\
    cat >! clearspace.sourceme
    set test = `cat clearspace.sourceme | wc -l`
    echo "ready to clear $test files from $cache "

    echo "everything okay with new tape? "
    set test = ( $< )
    echo "okay to clear tape cache? "
    set test = ( $< )

    source clearspace.sourceme

    rm -f clearspace.sourceme incache.txt ontape.txt

    cd $pwd
    goto newtape
endif

if("$stream" != "data") continue

echo "waiting for new images..."

echo -n "" | xos3_exchange.tcl 9999 image_ready 3600 |\
tee debug_xos.log |\
awk '! /image_ready/{next}\
   ! /[0-9]$/{n=split($NF,w,".");ext="." w[n]} {\
   prefix=substr($NF,1,length($NF)-length(ext));\
   num="";while(prefix~/[0-9]$/){\
       num=substr(prefix,length(prefix)) num;\
       prefix=substr(prefix,1,length(prefix)-1);\
   };\
   numw=length(num)}\
  #{print prefix,num}\
  lastprefix==prefix && prefix!=""{while(lastnum+0<num+0){\
    lastnum=sprintf("%0"numw"d",lastnum+1);print prefix lastnum ext;\
    }} {lastprefix=prefix;lastnum=num}' |\
tar cTf - - |\
tar xvCf $cache -

set test = `cat debug_xos.log | wc -l`
if( $test < 10 ) then
    echo "xos connection seems to have failed. Waiting..."
    set INSHUTDOWN
    sleep 900
endif

end


exit:

if($?BAD) then
    echo "ERROR: $BAD"
    exit 9
endif
exit

##################################################################
#
#   notes and example usage
#

# clear any mis-placed XDS output
find $dir -name .snapshot -prune -o \
    -name '*.cbf' -o -name '*.cbf.gz' |\
awk '/\/FRAME|\/GAIN|\/ABS|\/ABSORP|\/BKGINIT|\/BKGPIX|\/BLANK|\/DECAY| \/MODPIX|-CORRECTIONS/{\
  print "rm -f",$NF}' |\
tcsh -vf


cd /local/maintain_alsenable
ln -sf /filecache/alsenable_local/alsenable .

~jamesh/archiving/maintain_tapecache.com stream=alsenable dir=/alsenable/ dirhost=petabyte cache=/filecache/alsenable_local nowrite &


~jamesh/archiving/maintain_tapecache.com stream=alsenable dir=/alsenable/ dirhost=archive3 cache=/filecache/alsenable_local nowrite nodate &

./linkify_image_duplicates.com
./fix_image_dates.com


find data -type f -printf "%t %p\n" | awk '/ 2021 /{print $6}' > files_2021.txt

rsync -avn --files-from=files_2021.txt ./ petabyte::olddata/2021/


