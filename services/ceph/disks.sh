#!/bin/bash

# Build out MegaRAID devices
preflight_megaraid()
{
  # Clear foreign states
  sudo MegaCli -CfgForeign -Clear -aALL
}
build_megaraid()
{
  preflight_megaraid
  sudo megaclisas-status | grep Unconfigured | grep "HDD\|SSD" | while read -r line ;
  do
    adapter=$(echo $line | awk '{print $1}' | grep -o '[0-9]\+')
    device=$(echo $line | awk 'NR>1{print $1}' RS=[ FS=] | sed -e 's/N\/A//g')
    sudo MegaCli -CfgLdAdd -r0[$device] -a$adapter
  done
}
use_megaraid=0
ask_megaraid_ceph()
{
  no_it_mode=$(sudo megaclisas-status | grep "PERC H700\|NonJBODCard")
  if [ ! -z "$no_it_mode" ]
  then
    use_megaraid=1
  fi

  if [ $use_megaraid = 1 ]
  then
    if [ "$(megaclisas-status | grep -c Unconfigured)" -ge 1 ]
    then
      echo ''
      echo "Ceph works best with individual disk, but your controller does not support this."
      read -n1 -p "Do you want to prepare your unconfigured disks into individual RAID0 devices? [y,n]" doit
      case $doit in
        y|Y) echo '' && build_megaraid ;;
        n|N) echo '' && echo 'Disk were not prepared.' ;;
        *) ask_megaraid ;;
      esac
    else
      echo "MegaRAID is enabled, but there are no disks to configure."
    fi
  fi
}
ignore_dev=()
dev="$(lsblk -p -l -o kname | grep -v 'KNAME' | grep -v [0-9])"
dev_available=()
dev_spin=()
dev_ssd=()
preflight_ceph_osd()
{
  clear
  printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' =
  echo "COACH - Cluster Of Arbitrary, Cheap, Hardware"
  printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' =
  echo "Device Scanner || $HOSTNAME"
  printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
  echo "Scanning for storage devices..."

  ignore_dev=()
  dev="$(lsblk -p -l -o kname | grep -v 'KNAME' | grep -v [0-9])"
  dev_available=()
  dev_spin=()
  dev_ssd=()

  spin_count=0
  ssd_count=0
  if [ ! -z $(command -v megaclisas-status) ]
  then
    echo "MegaRAID controller found. "
    echo "Cleaning and preparing disks..."
    build_megaraid

    echo "Scanning for any RAID spans with more than 1 device. These will be ignored."
    raid_ignore=($(sudo megaclisas-status | grep Online | grep HDD | awk '{print $1}' | grep p1))
    raid_ignore=(${raid_ignore[@]} $(sudo megaclisas-status | grep Online | grep SSD | awk '{print $1}' | grep p1))
    raid_ignore=("${raid_ignore[@]}" "$(megaclisas-status | grep Online | grep SSD | awk '{print $1}' | grep p1)")
    ignore_count=0
    echo ""
    echo "Ignoring the following MegaRAID devices:"
    for line in "${raid_ignore}"
    do
      raid_id=$(echo $line | sed -r 's/(c[0-9]+u[0-9]+)(p1)/\1/')
      dev_id=$(sudo megaclisas-status | grep $raid_id | grep "/dev" | awk '{print $16}')
      ignore_dev=("${ignore_dev[@]}" "$dev_id")
      dev=$(echo "$dev" | grep -v "$dev_id")
      echo "  $raid_id		$dev_id"
    done
    echo ""
    echo "Scanning for MegaRAID hard disks..."
    found_spin=$(sudo megaclisas-status | grep Online | grep HDD)
    if [ ! -z "$found_spin" ]
    then
      raid_spin=($(echo "${found_spin[@]}" | awk '{print $1}' | grep p0))
      for line in "${raid_spin[@]}"
      do
        raid_id=$(echo $line | sed -r 's/(c[0-9]+u[0-9]+)(p0)/\1/')
        dev_id=$(sudo megaclisas-status | grep -w $raid_id | grep "/dev" | awk '{print $16}')
        should_ignore=$((for e in "${ignore_dev[@]}"; do [[ "$e" == "$dev_id" ]] && exit 0; done) && echo 1 || echo 0)
        if [ "$should_ignore" -lt 1 ]
        then
          dev_spin=("${dev_spin[@]}" "$dev_id")
          dev_available=("${dev_available[@]}" "$dev_id")
          dev=$(echo "$dev" | grep -v "$dev_id")
          echo "  $raid_id		$dev_id"
          spin_count=$[$spin_count + 1]
        fi
      done
    fi
    echo ""
    echo "Scanning for MegaRAID solid state disks..."
    found_ssd=$(sudo megaclisas-status | grep Online | grep SSD)
    if [ ! -z "$found_ssd" ]
    then
      raid_ssd=($(echo "${found_ssd[@]}" | awk '{print $1}' | grep p0))
      for line in "${raid_ssd[@]}"
      do
        raid_id=$(echo $line | sed -r 's/(c[0-9]+u[0-9]+)(p0)/\1/')
        dev_id=$(sudo megaclisas-status | grep -w $raid_id | grep "/dev" | awk '{print $16}')
        should_ignore=$((for e in "${ignore_dev[@]}"; do [[ "$e" == "$dev_id" ]] && exit 0; done) && echo 1 || echo 0)
        if [ "$should_ignore" -lt 1 ]
        then
          dev_ssd=("${dev_ssd[@]}" "$dev_id")
          dev_available=("${dev_available[@]}" "$dev_id")
          dev=$(echo "$dev" | grep -v "$dev_id")
          echo "  $raid_id		$dev_id"
          ssd_count=$[$ssd_count + 1]
        fi
      done
    fi
    echo ""
  fi
  if [ ! -z "$dev" ]
  then
    while read line
    do
      id=$(echo "$line" | awk '{split($0,a,"/"); print a[3]}')
      if [ -z "$(sudo cat /proc/mdstat | grep $id)" ]
      then
        if [ -z  $(lsblk -p -l -o kname | grep -e $line"[0-9]") ]
        then
          if [ $(lsblk -p -l -o kname,rota | grep -e $line | awk '{print $2}') -gt 0 ]
          then
            dev_spin=("${dev_spin[@]}" "$line")
            spin_count=$[$spin_count + 1]
          else
            dev_ssd=("${dev_ssd[@]}" "$line")
            ssd_count=$[$ssd_count + 1]
          fi
        else
          if [ $(lsblk -p -l -o kname,rota | grep -e $line | grep -v -e $line"[0-9]" | awk '{print $2}') -gt 0 ]
          then
            dev_spin=("${dev_spin[@]}" "$line")
            spin_count=$[$spin_count + 1]
          else
            dev_ssd=("${dev_ssd[@]}" "$line")
            ssd_count=$[$ssd_count + 1]
          fi
        fi
        dev_available=("${dev_available[@]}" "$line")
      fi
    done <<EOT
$(echo "$dev")
EOT
  fi
}
diff(){
  awk 'BEGIN{RS=ORS=" "}
       {NR==FNR?a[$0]++:a[$0]--}
  END{for(k in a)if(a[k])print k}' <(echo -n "${!1}") <(echo -n "${!2}")
}

menu_ceph_osd()
{
  RED='\033[1;31m'
  BLUE='\033[0;34m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  NC='\033[0m' # No Color
  counter=0
  add_selections=()
  remove_selections=()
  fix_selections=()
  clear
  printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' =
  echo "COACH - Cluster Of Arbitrary, Cheap, Hardware"
  printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' =
  echo "Available Devices || $HOSTNAME"
  printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
  echo "	PATH		TYPE	ACTIVITY"
  printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
  for dev_id in ${dev_available[@]}
  do
    counter=$[$counter +1]
    if [ $((for e in "${dev_available[@]}"; do [[ "$e" == "$dev_id" ]] && exit 0; done) && echo 1 || echo 0) -eq 1 ]
    then
      if [ ${#dev_spin[@]} -gt 0 ]
      then
        if [ $((for e in "${dev_spin[@]}"; do [[ "$e" == "$dev_id" ]] && exit 0; done) && echo 1 || echo 0) -eq 1 ]
        then
          if [ ! -z "$(sudo sgdisk $dev_id -p | grep 'ceph data')" ]
          then
            osd_id=$(mount | grep $dev_id | grep ceph | awk '{print $3}' | grep -Eo '[0-9]{1,4}')
            if [ -z "$osd_id" ]
            then
              in_use=$(sudo sgdisk $dev_id -p | sed -n -e '/Number/,$p' | grep -v Number | grep -v ceph)
              if [ -z "$in_use" ]
              then
                printf  "${BLUE}[$counter]${NC}	$dev_id	HDD	${BLUE}ORPHANED${NC}\n"
                add_selections=("${add_selections[@]}" "$counter")
              else
                printf "${YELLOW}[$counter]${NC}	$dev_id	HDD	${YELLOW}IN USE${NC}\n"
                add_selections=("${add_selections[@]}" "$counter")
              fi
            else
              printf  "${RED}[$counter]${NC}	$dev_id	HDD	${RED}(osd.$osd_id)${NC}\n"
              remove_selections=("${remove_selections[@]}" "$counter")
            fi
          else
            if [ -z $(lsblk -p -l -o kname | grep -e $dev_id"[0-9]") ]
            then
              printf "${GREEN}[$counter]${NC}	$dev_id	HDD\n"
              add_selections=("${add_selections[@]}" "$counter")
            fi
          fi
        fi
      fi
      if [ ${#dev_ssd[@]} -gt 0 ]
      then
        if [ $((for e in "${dev_ssd[@]}"; do [[ "$e" == "$dev_id" ]] && exit 0; done) && echo 1 || echo 0) -eq 1 ]
        then
          if [ ! -z "$(sudo sgdisk $dev_id -p | grep 'ceph data')" ]
          then
            osd_id=$(mount | grep $dev_id | grep ceph | awk '{print $3}' | grep -Eo '[0-9]{1,4}')
            if [ -z "$osd_id" ]
            then
              in_use=$(sudo sgdisk $dev_id -p | sed -n -e '/Number/,$p' | grep -v Number | grep -v ceph)
              if [ -z "$in_use" ]
              then
                printf  "${BLUE}[$counter]${NC}	$dev_id	SSD	${BLUE}ORPHANED${NC}\n"
                add_selections=("${add_selections[@]}" "$counter")
              else
                printf "${YELLOW}[$counter]${NC}	$dev_id	SSD	${YELLOW}IN USE${NC}\n"
                add_selections=("${add_selections[@]}" "$counter")
              fi
            else
              printf  "${RED}[$counter]${NC}	$dev_id	SSD	${RED}(osd.$osd_id)${NC}\n"
              remove_selections=("${remove_selections[@]}" "$counter")
            fi
          else
            if [ ! -z "$(sudo sgdisk $dev_id -p | grep 'ceph journal')" ]
            then
              parts=($(lsblk -p -l -o kname | grep -e $dev_id"[0-9]"))
              echo "	$dev_id	SSD	(${#parts[@]} Journals)"
            else
              if [ -z $(lsblk -p -l -o kname | grep -e $dev_id"[0-9]") ]
              then
                printf  "${GREEN}[$counter]${NC}	$dev_id	SSD\n"
                add_selections=("${add_selections[@]}" "$counter")
              fi
            fi
          fi
        fi
      fi
    fi
  done
  printf '%*s\n' "${COLUMNS:-$(tput cols)}" '' | tr ' ' -
  echo "[0]	BACK"
  echo ''
}

menu_ceph_osd