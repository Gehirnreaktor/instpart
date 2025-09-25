#!/bin/bash
export LANG=en_US.UTF-8

# Check if necessary programs are installed
if ! command -v whiptail &> /dev/null || ! command -v parted &> /dev/null || ! command -v mkfs &> /dev/null || ! command -v sgdisk &> /dev/null; then
    whiptail --title "Error" --msgbox "Error: 'whiptail', 'parted', 'mkfs', or 'sgdisk' not found.\nPlease install them first." 10 78
    exit 1
fi

# --- Phase 1: Device Selection ---
declare -a DEVICES_LIST=()
while read -r name size model vendor; do
    if [[ ! "$name" =~ ^(loop|sr|ram|cdrom) ]]; then
        DEVICES_LIST+=("$name" "$size - $model ($vendor)" "OFF")
    fi
done < <(lsblk -dno NAME,SIZE,MODEL,VENDOR)

if [ ${#DEVICES_LIST[@]} -eq 0 ]; then
    whiptail --title "Error" --msgbox "No physical drives found for partitioning." 10 78
    exit 1
fi

read -n 1 -s -r -p "Press any key to start the device selection..."

DEVICE_CHOICE=$(whiptail --title "Select Device" --radiolist "Please select a device to partition\n(WARNING: All data will be lost!)" 20 78 12 --backtitle "Disk Setup" "${DEVICES_LIST[@]}" 3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    whiptail --title "Aborted" --msgbox "Operation aborted by user." 10 78
    exit 1
fi

DEVICE="/dev/$DEVICE_CHOICE"

# --- Phase 2: Define Partitions ---
NUM_PARTITIONS=$(whiptail --title "Partitions" --inputbox "How many partitions should be created?" 10 78 "1" 3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    whiptail --title "Aborted" --msgbox "Operation aborted by user." 10 78
    exit 1
fi

if ! [[ "$NUM_PARTITIONS" =~ ^[0-9]+$ ]] || [ "$NUM_PARTITIONS" -eq 0 ]; then
    whiptail --title "Error" --msgbox "Invalid number.\nPlease enter a number > 0." 10 78
    exit 1
fi

declare -a partition_data
for ((i=1; i<=$NUM_PARTITIONS; i++)); do
    PART_SIZE=$(whiptail --title "Partition $i" --inputbox "Size for Partition $i (e.g., 10G, 512M)\nor leave empty for the remaining space:" 10 78 "" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        whiptail --title "Aborted" --msgbox "Operation aborted by user." 10 78
        exit 1
    fi
    
    FS_TYPE=$(whiptail --title "Filesystem" --inputbox "Filesystem type for Partition $i\n(e.g., ext4, btrfs, ntfs, xfs, linux-swap, fat32):" 10 78 "ext4" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        whiptail --title "Aborted" --msgbox "Operation aborted by user." 10 78
        exit 1
    fi

    PART_MOUNTPOINT=$(whiptail --title "Mount Point" --inputbox "Mount point for Partition $i\n(e.g., /mnt or /mnt/home; leave empty for none):" 10 78 "" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        whiptail --title "Aborted" --msgbox "Operation aborted by user." 10 78
        exit 1
    fi

    PART_FLAGS=$(whiptail --title "Partition Flags" --checklist "Select flags for Partition $i\n(Spacebar to select):" 20 78 12 \
    "boot" "Start-flag for UEFI/BIOS" OFF \
    "esp" "EFI System Partition" OFF \
    "swap" "Linux Swap" OFF \
    3>&1 1>&2 2>&3)

    if [ $? -ne 0 ]; then
        whiptail --title "Aborted" --msgbox "Operation aborted by user." 10 78
        exit 1
    fi
    
    PART_LABEL=$(whiptail --title "Partition Label" --inputbox "Optional label for Partition $i\n(e.g., 'arch-root', 'home'):" 10 78 "" 3>&1 1>&2 2>&3)
    if [ $? -ne 0 ]; then
        whiptail --title "Aborted" --msgbox "Operation aborted by user." 10 78
        exit 1
    fi
    
    partition_data+=("$PART_SIZE" "$FS_TYPE" "$PART_MOUNTPOINT" "$PART_FLAGS" "$PART_LABEL")
done

# --- Phase 3: Confirmation and Execution ---
confirmation_text="Summary:\nDevice: $DEVICE\n----------------------------------\n"
for ((i=0; i<$NUM_PARTITIONS; i++)); do
    size=${partition_data[$i*5]}
    fs_type=${partition_data[$i*5+1]}
    mountpoint=${partition_data[$i*5+2]}
    part_flags=${partition_data[$i*5+3]}
    part_label=${partition_data[$i*5+4]}
    
    if [ -z "$size" ]; then
        confirmation_text+="Partition $((i+1)): Remaining space, Filesystem: $fs_type, Mount Point: $mountpoint, Flags: $part_flags, Label: $part_label\n"
    else
        confirmation_text+="Partition $((i+1)): Size: $size, Filesystem: $fs_type, Mount Point: $mountpoint, Flags: $part_flags, Label: $part_label\n"
    fi
done

if (whiptail --title "Confirmation" --yesno "$confirmation_text\n\nDo you want to continue? All data on $DEVICE will be erased!" 20 78); then
    # Ensure disk is not mounted
    umount "${DEVICE}"* &>/dev/null

    # Erase all partition tables and signatures for a clean start
    sgdisk --zap-all "$DEVICE" &>/dev/null
    wipefs -a "$DEVICE" &>/dev/null

    # Kernel über neue Tabellen informieren
    partprobe "$DEVICE"
    udevadm settle

    # Create the GPT table
    parted -s "$DEVICE" mklabel gpt
    if [ $? -ne 0 ]; then
        whiptail --title "Error" --msgbox "Could not create GPT table." 10 78
        exit 1
    fi

    # Partition sizes in MiB and points
    declare -a partition_points
    start_point_mib=1
    for ((i=0; i<$NUM_PARTITIONS; i++)); do
        size_str=${partition_data[$i*5]}
        if [[ "$size_str" =~ ^([0-9]+)G$ ]]; then
            size_mib=$(echo "scale=0; ${BASH_REMATCH[1]} * 1024" | bc)
        elif [[ "$size_str" =~ ^([0-9]+)M$ ]]; then
            size_mib="${BASH_REMATCH[1]}"
        else
            size_mib=0
        fi
        
        if [ "$size_mib" -gt 0 ]; then
            end_point_mib=$(echo "scale=0; $start_point_mib + $size_mib - 1" | bc)
            end_point="${end_point_mib}MiB"
        else
            end_point="100%"
        fi
        
        partition_points+=("$start_point_mib" "$end_point")

        if [ "$end_point" != "100%" ]; then
            start_point_mib=$(echo "scale=0; $end_point_mib + 1" | bc)
        fi
    done

    # Create partitions
    for ((i=0; i<$NUM_PARTITIONS; i++)); do
        local_part_num=$((i+1))
        local_start=${partition_points[$i*2]}MiB
        local_end=${partition_points[$i*2+1]}
        local_fs_type=${partition_data[$i*5+1]}
        local_part_flags=${partition_data[$i*5+3]}
        local_part_label=${partition_data[$i*5+4]}
        
        parted -s "$DEVICE" mkpart primary ext2 "$local_start" "$local_end"
        if [ $? -ne 0 ]; then
            whiptail --title "Error" --msgbox "Could not create Partition $local_part_num." 10 78
            exit 1
        fi
        
        for flag in $local_part_flags; do
            flag_clean=$(echo "$flag" | tr -d '"')
            if [ -n "$flag_clean" ]; then
                parted -s "$DEVICE" set "$local_part_num" "$flag_clean" on
            fi
        done
        
        if [ -n "$local_part_label" ]; then
            parted -s "$DEVICE" name "$local_part_num" "$local_part_label"
        fi
    done
    
    udevadm settle

    # --- Formatting and Mounting ---
    for ((i=0; i<$NUM_PARTITIONS; i++)); do
        fs_type=${partition_data[$i*5+1]}
        mountpoint=${partition_data[$i*5+2]}
        part_label=${partition_data[$i*5+4]}
        
        if [[ "$DEVICE_CHOICE" == nvme* ]]; then
            partition="${DEVICE}p$((i+1))"
        else
            partition="${DEVICE}$((i+1))"
        fi

        if [ ! -b "$partition" ]; then
            whiptail --title "Error" --msgbox "Partition file $partition was not found.\nAborting." 10 78
            exit 1
        fi

        if [ "$fs_type" == "linux-swap" ]; then
            mkswap "$partition" || { whiptail --title "Error" --msgbox "Creation of swap $partition failed." 10 78; exit 1; }
        elif [ "$fs_type" == "fat32" ]; then
            mkfs.fat -F 32 "$partition" || { whiptail --title "Error" --msgbox "Creation of EFI $partition failed." 10 78; exit 1; }
        else
            mkfs."$fs_type" -F "$partition" || { whiptail --title "Error" --msgbox "Formatting $partition failed." 10 78; exit 1; }
        fi

        if [ -n "$mountpoint" ]; then
            mkdir -p "$mountpoint"
            mount "$partition" "$mountpoint" || { whiptail --title "Error" --msgbox "Mounting $partition to $mountpoint failed." 10 78; exit 1; }
        fi

        # Add entry to fstab (UUID preferred, fallback to LABEL if set)
        uuid=$(blkid -s UUID -o value "$partition")
        if [ -n "$part_label" ]; then
            echo "LABEL=$part_label   $mountpoint   $fs_type   defaults   0 2" >> /etc/fstab
        else
            echo "UUID=$uuid   $mountpoint   $fs_type   defaults   0 2" >> /etc/fstab
        fi
    done
    
    whiptail --title "Done!" --msgbox "Disk $DEVICE successfully partitioned, formatted, mounted, and added to fstab." 10 78
else
    whiptail --title "Aborted" --msgbox "Operation aborted by user." 10 78
    exit 1
fi
 