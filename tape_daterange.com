#! /bin/tcsh -f
#
# 
#
set log = "$1"
if(! -e "$log") then
    echo "usage: $0 epoch_stamped_list.log"
    exit 9
endif

set path = ( $path `dirname $0` )

set n = `cat $log | wc -l`

set first = `grep -v raster $log | head -n 1 | awk '{print int($1)}'`
set last  = `grep -v raster $log | tail -n 1 | awk '{print int($1)}'`

set slope_intercept = `grep -v raster $log | awk '$2>0{print ++n,$1}' | linfit.awk`

set rmsd = `grep -v raster $log | awk '$2>0{print ++n,$1}' | linfit.awk -v printout=1 | awk '{++n;sum+=($2-$3)^2} END{print sqrt(sum/n)}'`
set first_normal = `grep -v raster $log | awk '$2>0{print ++n,$1}' | linfit.awk -v printout=1 | awk -v rmsd=$rmsd '($2-$3)^2<(3*rmsd)^2{print last;print $2;getline; print $2;exit}' {last=$2}`
set last_normal  = `tac $log | grep -v raster | awk '$2>0{print ++n,$1}' | linfit.awk -v printout=1 | awk -v rmsd=$rmsd '($2-$3)^2<(3*rmsd)^2{print last;print $2;getline;print $2;exit} {last=$2}'`

set fit_start = `echo $slope_intercept | awk '{print int($2)}'`
set fit_end   = `echo $slope_intercept $n | awk '{print int($2+$1*$3)}'`


foreach epoch ( $first $first_normal $last_normal $last )

    echo "puts [clock format $epoch]" | tclsh

end

