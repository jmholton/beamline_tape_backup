#! /bin/tcsh -f
#
#   read back an LTO tape,  be agressive it gets stubborn
#
#
set devtape = "$1"

if("$devtape" == "") set devtape = /dev/tape

echo "driving $devtape"

# first, try to just read it
mt -f $devtape eod
set fulltape = `mt -f $devtape tell | awk '{print $NF+0}'`
echo "full tape is $fulltape blocks"
mt -f $devtape rewind

# drive it around a bit first?
set onetrack = `echo $fulltape 14 | awk '{print int($1/$2)}'`
set pos = 0
mt -f $devtape rewind
while ( $pos < $fulltape )
    @ pos = ( $pos + $onetrack )
    if( $pos > $fulltape ) set pos = $fulltape
    mt -f $devtape seek $pos
    if($status) then
        echo "got tape error on seek"
        set CRAPPY_TAPE
        mt -f $devtape eject ; mt -f $devtape load
    endif
    mt -f $devtape tell
    if($status) then
        echo "got tape error on tell"
        set CRAPPY_TAPE
        mt -f $devtape eject ; mt -f $devtape load
    endif
    mt -f $devtape rewind
    if($status) then
        echo "got tape error on rewind"
        set CRAPPY_TAPE
        mt -f $devtape eject ; mt -f $devtape load
    endif
end
mt -f $devtape rewind

if($?CRAPPY_TAPE) then
    foreach itr ( `seq 1 10` )

        set pos = 0
        mt -f $devtape rewind
        while ( $pos < $fulltape )
            @ pos = ( $pos + $onetrack )
            if( $pos > $fulltape ) set pos = $fulltape
            mt -f $devtape seek $pos
            mt -f $devtape tell
            mt -f $devtape rewind
        end
    end
endif

identify_tape.com $devtape |& tee identify_tape.log
mt -f $devtape load
egrep "^set " identify_tape.log >! sourceme.txt
source sourceme.txt
rm -f sourceme.txt

# pause if there is another tape doing something
set test = `ps -flea | grep dd | grep "dev/tape" | grep -v grep | wc -l`
while ( $test )
    echo "waiting for other tape to finish."
    sleep 900
    set test = `ps -flea | grep dd | grep "dev/tape" | grep -v grep | wc -l`
end

# now slect a cache disk
foreach cache ( /cache /cache2 )
    set test = `df $cache | tail -n 1 | awk '{print ( $4 > 1.7*1024**3 )}'`
    if( $test ) break
end

set fstream = "_$stream"
if("$stream" == "data") set fstream = ""
set tarprefix = ${cache}/tape_${tape}

#killall -STOP nc
killall -STOP dd
killall -STOP rsync
killall -STOP md5sum
sleep 10

# first, try normal read-back
set pos = `mt -f $devtape tell | awk '{print $NF+0}'`
echo "reading $devtape from pos $pos into ${tarprefix}_pos$pos"
dd bs=8M if=$devtape of=${tarprefix}_pos$pos
if(! $status) then
    killall -CONT nc
    killall -CONT dd
    killall -CONT rsync
    killall -CONT md5sum
    goto checkend
endif

set CRAPPY_TAPE
set newpos = `mt -f $devtape tell | awk '$NF+0>0{print $NF+0}'`


# try seeking around a lot
# LTO4 = 14 wraps/band
# LTO6 = 34 wraps/band
set onetrack = `echo $fulltape 14 | awk '{print int($1/$2)}'`
foreach itr ( `seq 1 10` )

    set pos = 0
    mt -f $devtape rewind
    while ( $pos < $fulltape )
        @ pos = ( $pos + $onetrack )
        if( $pos > $fulltape ) set pos = $fulltape
        mt -f $devtape seek $pos
        mt -f $devtape tell
        mt -f $devtape rewind
    end
end



set pos = 0
mt -f $devtape rewind
while ( $pos < $fulltape )

if(-e ${tarprefix}_pos$pos) then
    set pos = `ls -l ${tarprefix}_pos$pos | awk '{print int($5/8/1024/1024)+50}'`
endif

mt -f $devtape seek $pos
if($status) then
    mt -f $devtape eject
    mt -f $devtape load
    @ pos = ( $pos + 250 )
    continue
endif

dd bs=8M if=$devtape of=${tarprefix}_pos$pos

set newpos = `mt -f $devtape tell | awk '$NF+0>0{print $NF+0}'`
echo "at block $newpos"
if("$newpos" != "") then
    set pos = $newpos
else
    set blocks = `ls -l ${tarprefix}_pos$pos | awk '{print int($5/8/1024/1024)}'`
    set newpos = `echo $pos $blocks | awk '{print int($1+$2)}'`
endif
@ pos = ( $newpos + 100 )

end

checkend:
# check end of tape
set lasttar = `ls -1 ${tarprefix}_pos* | sort -g | tail -n 1`
set skip = `ls -l $lasttar | awk '{print int($5/8/1024/1024)-20}'`
( dd bs=8M skip=$skip if=$lasttar | tar tivf - >! lastgasp.txt ) >& /dev/null

set finalfile = `tail -n 1 /data/log/LTO/backup_LTO_${stream}_${tape}.log | awk '{print substr($NF,2)}'`
grep "$finalfile" lastgasp.txt
if(! $status) then
    echo "got last file."
    mt -f $devtape eject
    if(! $?CRAPPY_TAPE) goto exit
endif




# can it be stitched together?
rm sortme.txt
foreach tarfile ( `ls -1 ${tarprefix}_pos* | sort -k1.22g` )

set pos = `echo $tarfile | awk -F "pos" '{print $NF}'`
set len = `ls -l $tarfile | awk '{print int($5/8/1024/1024)}'`

echo "$pos $len $tarfile" | awk '{printf("%6d %6d %s\n",$1,$1+$2,$3)}' | tee -a sortme.txt

end
#sort -g sortme.txt










mkdir -p /filecache/recovery/data$tape
cd /filecache/recovery/data$tape

set dvddir = /media/CDROM/
set cache = /cache/
if(! -w ${cache}) set cache = ../
if(! -w ${cache}) set cache = ./

if(! $?tarprefix) set tarprefix = ${cache}/tape_${tape}

# check which files are still missing
set tarfiles = `ls -1rt ${tarprefix}_*`
foreach tarfile ( $tarfiles )
    set pos = `echo $tarfile | awk -F "_" '{print $NF}'`
    echo $pos
    if(-e tarlist_${pos}.log) continue
    tar tivf $tarfile --utc --full-time  >! tarlist_${pos}.log
end
echo -n "" >! readable.log
foreach tarlist ( `ls -1rt tarlist_*.log` )
    set skiplast = `echo $tarlist | awk '{print ( /_pos/ )}'`
    echo "$tarlist  $skiplast"
    cat $tarlist |\
    awk '! /^tar: /' |\
    awk '{print "set epoch [clock scan \""$4,$5,"UTC\"]";\
          gsub("[\"\\[\\]\\$]","\\\\&");\
          print "puts \"$epoch "$3" [clock format $epoch -format \"%a %b %d %T %Z %Y\"] /"$6"\""}' |\
    tclsh |\
    awk -v skiplast=$skiplast 'skiplast==0{print} last!=""{print last} {last=$0}' |\
    cat >> readable.log
end
sort -u readable.log | sort -g >! tempfile.log
mv tempfile.log readable.log

if(! -e right_sums.txt ) then
    awk 'NR==1{s=$1} END{print s,$1}' /data/log/LTO/backup_LTO_${stream}_${tape}.log |\
    cat -  /data/log/image_checksums_all.log |\
    awk 'NR==1{start=$1-3600*24*365;end=$2+3600*24*365;next}\
        $1>start && $1<end{print}' |\
    cat >!  right_sums.txt
endif
if(! -e all_system_dvds.log ) then
    cp /data/log/all_system_dvds.log .
endif

awk '{print $0,"READABLE"}' readable.log |\
cat - /data/log/LTO/backup_LTO_${stream}_${tape}.log |\
awk '$NF=="READABLE"{++readed[$1,$9];next}\
   ! readed[$1,$9]{print $0,"NEED"}' |\
tee needed_files.txt |\
cat - right_sums.txt |\
awk '$NF=="NEED"{++need[$1,$9];next}\
  need[$1,$4]{print}' |\
tee needed_sums.txt |\
awk '{for(i=5;i<=NF;++i)print $i}' |\
awk '! seen[$1]{++seen[$1];print}' |\
tee needed_DVDs.txt |\
cat all_system_dvds.log - |\
awk '/^SYSTEM/{++sysdvd[$2];next}\
  sysdvd[$1]{print}' |\
sort -g >! needed_sysDVDs.txt
set needed_files = `cat needed_files.txt | wc -l`
set needed_DVDs = `cat needed_sysDVDs.txt | wc -l`
echo "still need $needed_files files from $needed_DVDs DVDs"
awk '{++n;printf("%s ",$1)} n%10==0{print ""} END{print ""}' needed_sysDVDs.txt


foreach sysDVD ( `cat needed_sysDVDs.txt` )

echo "please insert DVD #$sysDVD "
while ( ! -r ${dvddir}/data )
    mkdir -p $dvddir
    mount -o ro /dev/sr0 $dvddir >& /dev/null
    sleep 3
end
sleep 1

set info = `identify_dvd.com $dvddir | tail -n 1`
echo "DVD is $info"
set truDVD = $info[$#info]

set tarfile = ${tarprefix}_dvd$truDVD
while (-e "$tarfile")
    set tarfile = "${tarfile}a"
end

find $dvddir -printf "%T@ /%P\n" |\
awk '{print int($1),$2}' |\
cat needed_files.txt - |\
awk 'NF>3{++needed[$1,$4];next}\
  needed[$1,$2]{print substr($2,2)}' |\
tar cvCTf $dvddir - $tarfile

eject $dvddir

end

exit:

if($?BAD) then
    echo "ERROR: $BAD"
    exit 9
endif

exit





