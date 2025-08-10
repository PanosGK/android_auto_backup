#!/bin/bash

# =========================================================================
# ===            Unified Android Backup & USB Mount Utility             ===
# =========================================================================
# This script combines mounting a USB drive, backing up an Android device
# to either the USB or the local computer, and then unmounting the drive.
#
# v7.0: Added VCF contact file detection and counting.
# =========================================================================

# --- Sudo Check: Ensure script is run as root ---
if [[ $EUID -ne 0 ]]; then
   echo "This script needs admin rights to work. Trying again..."
   exec sudo -- "$0" "$@"
   exit 1
fi

# =========================================================================
# ---                         CONFIGURATION                             ---
# =========================================================================

USB_MOUNT_FOLDER_NAME="Android_Backup_USB"
ANDROID_ROOT_DIR="/sdcard"
FOLDERS_TO_COPY=(
    "DCIM" "Pictures" "Movies" "Download" "Documents" "Downloads" "WhatsApp" "Viber"
)

if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    ORIGINAL_USER="$SUDO_USER"
else
    USER_HOME=$HOME
    ORIGINAL_USER=$(whoami)
fi

LOCAL_BACKUP_BASE_DIR="$USER_HOME/Desktop/Android_Backups"
RESET="\033[0m"; BOLD="\033[1m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; RED="\033[0;31m"; BLUE="\033[0;34m"

# =========================================================================
# ---                       UTILITY FUNCTIONS                           ---
# =========================================================================

function update_progress() {
    local message="$1"
    local current_step=$2
    local total_steps=$3
    (( total_steps == 0 )) && total_steps=1
    local bar_length=30
    local filled_chars=$(( (current_step * bar_length) / total_steps ))
    local empty_chars=$(( bar_length - filled_chars ))
    local filled=""
    for ((i=0; i<filled_chars; i++)); do filled+="#"; done
    local empty=""
    for ((i=0; i<empty_chars; i++)); do empty+="-"; done
    if (( ${#message} > 60 )); then
        message="${message:0:57}..."
    fi
    printf "\r%*s\r" "$(tput cols)" "" >&3
    echo -ne "[${filled}${empty}] ($current_step/$total_steps) | ${message}\r" >&3
}

function count_vcf_contacts() {
    # Counts the number of "BEGIN:VCARD" entries in a given file.
    local vcf_file="$1"
    if [[ -f "$vcf_file" ]]; then
        grep -c '^BEGIN:VCARD' "$vcf_file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# =========================================================================
# ---                      CORE LOGIC FUNCTIONS                         ---
# =========================================================================

function mount_usb() {
    echo -e "${BLUE}--- Preparing Your USB Drive ---${RESET}" >&2
    local MOUNT_POINT="$USER_HOME/Desktop/$USB_MOUNT_FOLDER_NAME"
    local USB_DISK_PATH=$(lsblk -p -o NAME,TRAN,TYPE -n | awk '$2=="usb" && $3=="disk" {print $1; exit}')
    if [[ -z "$USB_DISK_PATH" ]]; then
        echo -e "${RED}Error: Could not find a USB drive.${RESET}" >&2
        return 1
    fi
    local DEVICE="${USB_DISK_PATH}1"
    if [ ! -b "$DEVICE" ]; then
        echo -e "${RED}Error: Found a USB drive, but could not find a partition on it.${RESET}" >&2
        return 1
    fi
    umount "$MOUNT_POINT" &> /dev/null
    if [ ! -d "$MOUNT_POINT" ]; then
        mkdir -p "$MOUNT_POINT"
        chown "$ORIGINAL_USER:$(id -gn "$ORIGINAL_USER")" "$MOUNT_POINT"
    fi
    local USER_ID=$(id -u "$ORIGINAL_USER")
    local GROUP_ID=$(id -g "$ORIGINAL_USER")
    echo "Please wait..." >&2
    if mount -o "uid=$USER_ID,gid=$GROUP_ID" "$DEVICE" "$MOUNT_POINT"; then
        echo -e "${GREEN}OK. Your USB drive is ready.${RESET}" >&2
        echo "$MOUNT_POINT"
        return 0
    else
        echo -e "${RED}Error: Could not get the USB drive ready for backup.${RESET}" >&2
        rmdir "$MOUNT_POINT" &> /dev/null
        return 1
    fi
}

function unmount_usb() {
    local MOUNT_POINT="$1"
    [[ -z "$MOUNT_POINT" ]] && return 1
    echo -e "${BLUE}--- Ejecting USB Drive ---${RESET}"
    echo "Please wait..."
    if findmnt -r --target "$MOUNT_POINT" > /dev/null; then
        if umount "$MOUNT_POINT"; then
            rmdir "$MOUNT_POINT" &> /dev/null
            echo -e "${GREEN}Done. You can now safely remove the USB drive.${RESET}"
        else
            echo -e "${YELLOW}Warning: Could not eject the drive. A program may still be using it.${RESET}"
        fi
    else
        rmdir "$MOUNT_POINT" &> /dev/null
        echo -e "${GREEN}Done. You can now safely remove the USB drive.${RESET}"
    fi
    return 0
}

function generate_log_report() {
    local log_file="$1"
    local device_model="$2"
    local dest_dir="$3"
    # The remaining arguments are the arrays and vars, passed by name
    local -n successful_ref="$4"
    local -n skipped_ref="$5"
    local -n failed_ref="$6"
    local contact_count="$7"
    local vcf_file_path="$8"

    # Create or overwrite the log file
    {
        echo "====================================================="
        echo "               Android Backup Log"
        echo "====================================================="
        echo "Date:           $(date)"
        echo "Phone Model:    $device_model"
        echo "Backup Location: $dest_dir"
        echo "-----------------------------------------------------"
        echo ""
        echo "--- Summary ---"
        echo "Successfully Copied: ${#successful_ref[@]} files"
        echo "Skipped (Up to Date): ${#skipped_ref[@]} files"
        echo "Failed to Copy:      ${#failed_ref[@]} files"
        echo ""

        echo "--- Contacts Summary ---"
        if [[ "$contact_count" -gt 0 ]]; then
            echo "Contacts Found: $contact_count in file '$vcf_file_path'"
        else
            echo "Contacts Found: 0"
        fi
        echo ""

        echo "====================================================="
        echo "--- Successfully Copied Files (${#successful_ref[@]}) ---"
        echo "====================================================="
        printf "%s\n" "${successful_ref[@]}"
        echo ""

        if [ "${#skipped_ref[@]}" -gt 0 ]; then
            echo "====================================================="
            echo "--- Skipped Files (Already Up to Date) (${#skipped_ref[@]}) ---"
            echo "====================================================="
            printf "%s\n" "${skipped_ref[@]}"
            echo ""
        fi

        if [ "${#failed_ref[@]}" -gt 0 ]; then
            echo "====================================================="
            echo "--- FAILED TO COPY (${#failed_ref[@]}) ---"
            echo "====================================================="
            printf "%s\n" "${failed_ref[@]}"
            echo ""
        fi
    } > "$log_file"
}

function backup_android() {
    local BASE_DEST_DIR="$1"
    [[ -z "$BASE_DEST_DIR" ]] && return 1

    exec 3>&1 # Save terminal for progress output

    if ! command -v adb &> /dev/null; then
        echo -e "${YELLOW}Just a moment, need to install a helper tool (ADB)...${RESET}" >&3
        sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y android-tools-adb >/dev/null 2>&1
    fi
    if ! command -v adb &> /dev/null; then echo -e "${RED}Error: Could not install helper tool.${RESET}" >&3; return 1; fi

    echo -e "${BLUE}Please connect your phone and allow 'USB Debugging'.${RESET}" >&3
    local DEVICE_MODEL
    while true; do
        update_progress "Waiting for your phone..." 0 1 >&3
        if adb get-state &>/dev/null; then
            DEVICE_MODEL=$(adb shell getprop ro.product.model | tr -d '\r' | sed 's/ /_/g')
            [ -z "$DEVICE_MODEL" ] && DEVICE_MODEL="My_Phone"
            break
        fi
        sleep 3
    done

    local DEST_DIR="${BASE_DEST_DIR}/${DEVICE_MODEL}"
    mkdir -p "$DEST_DIR"
    local LOG_FILE="${DEST_DIR}/backup_log.txt"
    
    printf "\r%*s\r" "$(tput cols)" >&3
    echo -e "${GREEN}OK. Connected to your ${BOLD}$DEVICE_MODEL${RESET}." >&3; echo "" >&3
    
    update_progress "Analyzing files on phone..." 0 1 >&3
    local all_files_on_phone=()
    while IFS= read -r line; do
        all_files_on_phone+=("$line")
    done < <(adb shell "find ${FOLDERS_TO_COPY[@]/#/${ANDROID_ROOT_DIR}/} -path '*/.*' -prune -o -type f -exec stat -c '%s;%Y;%n' {} + 2>/dev/null")
    local total_files_to_process=${#all_files_on_phone[@]}

    # --- Main Backup Loop ---
    local -a successful_files=()
    local -a skipped_files=()
    local -a failed_files=()
    local files_processed=0

    for file_entry in "${all_files_on_phone[@]}"; do
        files_processed=$((files_processed + 1))
        IFS=';' read -r SOURCE_FILE_SIZE SOURCE_FILE_MTIME SOURCE_FULL_PATH_ON_PHONE <<< "$file_entry"
        SOURCE_FULL_PATH_ON_PHONE=$(echo "$SOURCE_FULL_PATH_ON_PHONE" | tr -d '\r')
        [[ -z "$SOURCE_FULL_PATH_ON_PHONE" ]] && continue
        
        local RELATIVE_PATH="${SOURCE_FULL_PATH_ON_PHONE#${ANDROID_ROOT_DIR}/}"
        local LOCAL_FILE_PATH="${DEST_DIR}/${RELATIVE_PATH}"

        update_progress "Checking: $RELATIVE_PATH" "$files_processed" "$total_files_to_process" >&3

        if [ -f "$LOCAL_FILE_PATH" ] && [ "$SOURCE_FILE_SIZE" -eq "$(stat -c %s "$LOCAL_FILE_PATH" 2>/dev/null)" ]; then
            skipped_files+=("$RELATIVE_PATH")
        else
            mkdir -p "$(dirname "$LOCAL_FILE_PATH")"
            if adb pull "$SOURCE_FULL_PATH_ON_PHONE" "$LOCAL_FILE_PATH" &>/dev/null; then
                successful_files+=("$RELATIVE_PATH")
            else
                failed_files+=("$RELATIVE_PATH")
            fi
        fi
    done

    # --- Find and Count VCF Contacts ---
    local contact_count=0
    local vcf_file_path=""
    mapfile -t vcf_files_found < <(find "$DEST_DIR" -type f -name "*.vcf")
    if [ "${#vcf_files_found[@]}" -gt 0 ]; then
        vcf_file_path="${vcf_files_found[0]}" # Use the first one found
        contact_count=$(count_vcf_contacts "$vcf_file_path")
    fi

    # --- Generate Log and Finalize ---
    printf "\r%*s\r" "$(tput cols)" >&3 # Clear progress bar
    generate_log_report "$LOG_FILE" "$DEVICE_MODEL" "$DEST_DIR" successful_files skipped_files failed_files "$contact_count" "$vcf_file_path"

    echo -e "${GREEN}${BOLD}--- Backup Complete! ---${RESET}" >&3
    echo -e "  ${BOLD}Copied:${RESET} ${#successful_files[@]} new files." >&3
    echo -e "  ${BOLD}Skipped:${RESET} ${#skipped_files[@]} files (already exist)." >&3
    if [ "${#failed_files[@]}" -gt 0 ]; then
        echo -e "  ${RED}${BOLD}Failed:${RESET} ${#failed_files[@]} files. Check log for details.${RESET}" >&3
    fi
    echo "" >&3
    
    # --- Display Contact Info ---
    if [[ "$contact_count" -gt 0 ]]; then
        local vcf_folder
        vcf_folder=$(dirname "$vcf_file_path")
        echo -e "${GREEN}${BOLD}Contacts Found:${RESET}" >&3
        echo -e "  Counted ${BOLD}$contact_count contacts${RESET}${GREEN} in a file inside the folder:${RESET}" >&3
        echo -e "  ${BLUE}$vcf_folder${RESET}" >&3
        if [ "${#vcf_files_found[@]}" -gt 1 ]; then
            echo -e "  ${YELLOW}(Note: Multiple contact files were found. Count is from the first file.)${RESET}" >&3
        fi
    else
        echo -e "${YELLOW}Note: No phone contact files were found in this backup.${RESET}" >&3
    fi

    echo "" >&3
    echo -e "A detailed report was saved to: ${BLUE}$LOG_FILE${RESET}" >&3
    echo "" >&3
    
    return 0
}

# =========================================================================
# ---                          MAIN MENU                              ---
# =========================================================================
function main_menu() {
    while true; do
        clear
        echo -e "${BOLD}--- Phone Backup Tool ---${RESET}"
        echo ""
        echo -e "   ${GREEN}--- Full Backup ---${RESET}"
        echo -e "   ${YELLOW}1)${RESET} Backup to connected ${BOLD}USB Drive${RESET} (Mount -> Backup -> Eject)"
        echo -e "   ${YELLOW}2)${RESET} Backup to the ${BOLD}Computer's Desktop${RESET}"
        echo ""
        echo -e "   ${BLUE}--- Manual USB Control ---${RESET}"
        echo -e "   ${YELLOW}3)${RESET} Mount USB Drive Only"
        echo -e "   ${YELLOW}4)${RESET} Eject USB Drive Only"
        echo ""
        echo -e "   ${YELLOW}5)${RESET} Exit"
        echo ""
        read -p "Type a number and press Enter: " choice

        case $choice in
            1)
                echo ""
                local usb_path=$(mount_usb)
                if [ -n "$usb_path" ] && mountpoint -q "$usb_path"; then
                    backup_android "$usb_path"
                    read -p "Press Enter to safely eject the USB drive..."
                    unmount_usb "$usb_path"
                fi
                echo -e "\nReturning to the main menu..."
                sleep 3
                ;;
            2)
                echo ""
                backup_android "$LOCAL_BACKUP_BASE_DIR"
                read -p "Press Enter to return to the main menu..."
                ;;
            3)
                echo ""
                mount_usb >/dev/null
                read -p "Press Enter to return to the main menu..."
                ;;
            4)
                echo ""
                local mount_point_to_check="$USER_HOME/Desktop/$USB_MOUNT_FOLDER_NAME"
                unmount_usb "$mount_point_to_check"
                read -p "Press Enter to return to the main menu..."
                ;;
            5)
                echo "Goodbye!"
                break
                ;;
            *)
                echo -e "\n${RED}Invalid choice. Please type a number from 1 to 5.${RESET}"
                sleep 2
                ;;
        esac
    done
}

# --- Start Execution ---
main_menu
