#!/bin/bash

# Show help in French
function show_help() {
  echo "Utilisation : $0 --hostname <IP_Address> --mode <Mode> --token <Access_Token> [OPTIONS]"
  echo
  echo "Modes available :"
  echo "  volumegrouphealth       Vérifie l'état de santé du RAID d'un groupe de volumes."
  echo "  volumegroupfreespace    Vérifie l'utilisation de l'espace d'un groupe de volumes."
  echo "  volumehealth            Vérifie l'état de santé d'un volume spécifique."
  echo "  diskhealth              Vérifie l'état de santé de tous les disques."
  echo "  psu                     Vérifie l'état de santé de toutes les alimentations."
  echo "  fan                     Vérifie l'état de santé de tous les ventilateurs."
  echo "  cputemp                 Vérifie les températures des CPU."
  echo "  hddtemp                 Vérifie les températures des disques durs."
  echo "  inlettemp               Vérifie les températures des entrées d'air."

  echo
  echo "Description :"
  echo "  Ce script supervise une baie de stockage Lenovo DE4000H via l'API REST."
  echo
  echo "Options :"
  echo "  --hostname        Adresse IP de la baie de stockage"
  echo "  --mode            Mode de supervision"
  echo "  --token           Access token pour authentification à l'API"
  echo "  --volumegroup     Nom du groupe de volumes à superviser (pour modes volumegrouphealth & volumegroupfreespace)"
  echo "  --volumename      Nom du volume à superviser (nécessaire pour le mode volumehealth)"
  echo "  --warning         Seuil pour avertissement"
  echo "  --critical        Seuil pour erreur critique"
  echo "  --debug           Active le mode débogage pour afficher la Request et la réponse brute"
  echo "  --help            Affiche cette aide"
  echo
  echo "Exemples :"
  echo "  $0 --hostname 192.168.1.150 --mode volumegrouphealth --volumegroup MyVolumeGroup --token example_token123"
  echo "  $0 --hostname 192.168.1.150 --mode volumegroupfreespace --volumegroup MyVolumeGroup --token example_token123 --warning 80 --critical 90"
  echo "  $0 --hostname 192.168.1.150 --mode volumehealth --volumename DS-VG-HDD-01 --token example_token123"
  echo "  $0 --hostname 192.168.1.150 --mode diskhealth --token example_token123"
  echo "  $0 --hostname 192.168.1.150 --mode psu --token example_token123"
  echo "  $0 --hostname 192.168.1.150 --mode fan --token example_token123"
  echo "  $0 --hostname 192.168.1.150 --mode cputemp --token example_token123 --warning 60 --critical 70"
  echo "  $0 --hostname 192.168.1.150 --mode hddtemp --token example_token123 --warning 40 --critical 50"
  echo "  $0 --hostname 192.168.1.150 --mode inlettemp --token example_token123 --warning 30 --critical 35"
}

# Init var
HOSTNAME=""
TOKEN=""
VOLUMEGROUP=""
VOLUMENAME=""
MODE=""
WARNING=""
CRITICAL=""
DEBUG=false

# Check parameters
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)
      HOSTNAME="$2"
      shift 2
      ;;
    --token)
      TOKEN="$2"
      shift 2
      ;;
    --volumegroup)
      VOLUMEGROUP="$2"
      shift 2
      ;;
    --volumename)
      VOLUMENAME="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --warning)
      WARNING="$2"
      shift 2
      ;;
    --critical)
      CRITICAL="$2"
      shift 2
      ;;
    --debug)
      DEBUG=true
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown setting : $1"
      exit 1
      ;;
  esac
done

# Check global parameters required
if [[ -z "$HOSTNAME" ]]; then
  echo "Error : missing parameter --hostname"
  exit 1
fi

if [[ -z "$TOKEN" ]]; then
  echo "Error : missing parameter --token"
  exit 1
fi

if [[ -z "$MODE" ]]; then
  echo "Error : missing parameter --mode"
  exit 1
fi

# Function get max temperature
function get_max_temp() {
  local temps="$1"
  echo "$temps" | tr ' ' '\n' | sort -nr | head -n 1
}

if [[ "$MODE" == "diskhealth" ]]; then
  API_URL="https://$HOSTNAME/devmgr/v2/storage-systems/1/drives"
  response=$(curl -k -s -X GET "$API_URL" -H "Authorization: Bearer $TOKEN" -H "accept: application/json")

  # debug mode
  if [[ "$DEBUG" == true ]]; then
    echo "Request : curl -k -s -X GET \"$API_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"accept: application/json\""
    echo "Raw JSON :"
    echo "$response"
    echo
  fi

  failed_disk=$(echo "$response" | jq -r '.[] | select(.status == "failed") | .physicalLocation.slot')
  total_disks=$(echo "$response" | jq -r 'length')

  if [[ -n "$failed_disk" ]]; then
    echo "CRITICAL: Disk N° $failed_disk is in failed status."
    exit 2
  else
    echo "OK: All disks ($total_disks) are optimal."
    exit 0
  fi
fi

if [[ "$MODE" == "volumegrouphealth" ]]; then
  API_URL="https://$HOSTNAME/devmgr/v2/storage-systems/1/storage-pools"
  response=$(curl -k -s -X GET "$API_URL" -H "Authorization: Bearer $TOKEN" -H "accept: application/json")

  if [[ "$DEBUG" == true ]]; then
    echo "Request : curl -k -s -X GET \"$API_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"accept: application/json\""
    echo "Raw JSON :"
    echo "$response"
    echo
  fi

  group_data=$(echo "$response" | jq -e --arg name "$VOLUMEGROUP" '.[] | select(.name == $name)')

  if [[ -z "$group_data" ]]; then
    available_groups=$(echo "$response" | jq -r '.[].name' | tr '\n' ', ' | sed 's/, $//')
    echo "CRITICAL: Volume group \"$VOLUMEGROUP\" not found. Volumes available : $available_groups"
    exit 2
  fi

  raid_status=$(echo "$group_data" | jq -r '.raidStatus')
  if [[ "$raid_status" == "optimal" ]]; then
    echo "OK: Volume group \"$VOLUMEGROUP\" is \"$raid_status\""
    exit 0
  else
    echo "CRITICAL: Volume group \"$VOLUMEGROUP\" is \"$raid_status\""
    exit 2
  fi
fi

if [[ "$MODE" == "volumegroupfreespace" ]]; then
  if [[ -z "$WARNING" ]]; then
    echo "Error : missing parameter --warning"
    exit 1
  fi
  if [[ -z "$CRITICAL" ]]; then
    echo "Error : missing parameter --critical"
    exit 1
  fi
  API_URL="https://$HOSTNAME/devmgr/v2/storage-systems/1/storage-pools"
  response=$(curl -k -s -X GET "$API_URL" -H "Authorization: Bearer $TOKEN" -H "accept: application/json")

  if [[ "$DEBUG" == true ]]; then
    echo "Request : curl -k -s -X GET \"$API_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"accept: application/json\""
    echo "Raw JSON :"
    echo "$response"
    echo
  fi

  group_data=$(echo "$response" | jq -e --arg name "$VOLUMEGROUP" '.[] | select(.name == $name)')

  if [[ -z "$group_data" ]]; then
    echo "CRITICAL: Volume group \"$VOLUMEGROUP\" not found."
    exit 2
  fi

  total_space=$(echo "$group_data" | jq -r '.totalRaidedSpace | tonumber')
  used_space=$(echo "$group_data" | jq -r '.usedSpace | tonumber')
  free_space=$((total_space - used_space))
  usage_percentage=$(awk "BEGIN {printf \"%.2f\", ($used_space / $total_space) * 100}")

  if (( $(echo "$usage_percentage >= $CRITICAL" | bc -l) )); then
    echo "CRITICAL: Volume group \"$VOLUMEGROUP\" Usage is ${usage_percentage}%"
    exit 2
  elif (( $(echo "$usage_percentage >= $WARNING" | bc -l) )); then
    echo "WARNING: Volume group \"$VOLUMEGROUP\" Usage is ${usage_percentage}%"
    exit 1
  else
    echo "OK: Volume group \"$VOLUMEGROUP\" Usage is ${usage_percentage}%"
    exit 0
  fi
fi

if [[ "$MODE" == "volumehealth" ]]; then
  API_URL="https://$HOSTNAME/devmgr/v2/storage-systems/1/volumes"
  response=$(curl -k -s -X GET "$API_URL" -H "Authorization: Bearer $TOKEN" -H "accept: application/json")

  if [[ "$DEBUG" == true ]]; then
    echo "Request : curl -k -s -X GET \"$API_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"accept: application/json\""
    echo "Raw JSON :"
    echo "$response"
    echo
  fi

  volume_data=$(echo "$response" | jq -e --arg name "$VOLUMENAME" '.[] | select(.name == $name)')

  if [[ -z "$volume_data" ]]; then
    available_volumes=$(echo "$response" | jq -r '.[].name' | tr '\n' ', ' | sed 's/, $//')
    echo "CRITICAL: Volume \"$VOLUMENAME\" not found. Volumes available : $available_volumes"
    exit 2
  fi

  status=$(echo "$volume_data" | jq -r '.status')
  mapped=$(echo "$volume_data" | jq -r '.mapped')
  capacity=$(echo "$volume_data" | jq -r '.capacity')
  capacity_tb=$(awk "BEGIN {printf \"%.2f\", $capacity / 1e12}")

  if [[ "$status" == "optimal" && "$mapped" == "true" ]]; then
    echo "OK: Volume \"$VOLUMENAME\" is \"$status\", size \"$capacity_tb\" To"
    exit 0
  else
    echo "CRITICAL: Volume \"$VOLUMENAME\" is \"$status\" or not mapped."
    exit 2
  fi
fi

if [[ "$MODE" == "psu" ]]; then
  API_URL="https://$HOSTNAME/devmgr/v2/storage-systems/1/hardware-inventory"
  response=$(curl -k -s -X GET "$API_URL" -H "Authorization: Bearer $TOKEN" -H "accept: application/json")

  if [[ "$DEBUG" == true ]]; then
    echo "Request : curl -k -s -X GET \"$API_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"accept: application/json\""
    echo "Raw JSON :"
    echo "$response"
    echo
  fi

  power_supplies=$(echo "$response" | jq -c '.powerSupplies[] | {ref: .powerSupplyRef, status: .status}')

  critical_found=false
  output=""
  while IFS= read -r supply; do
    ref=$(echo "$supply" | jq -r '.ref')
    status=$(echo "$supply" | jq -r '.status')

    if [[ "$status" != "optimal" ]]; then
      critical_found=true
      output+="CRITICAL: Power supply $ref is in status $status\n"
    fi

  done <<< "$power_supplies"

  if $critical_found; then
    echo -e "$output"
    exit 2
  else
    supply_count=$(echo "$power_supplies" | wc -l)
    echo "OK: All $supply_count power supplies are optimal."
    exit 0
  fi
fi

if [[ "$MODE" == "fan" ]]; then
  # Get data from API
  API_URL="https://$HOSTNAME/devmgr/v2/storage-systems/1/hardware-inventory"
  response=$(curl -k -s -X GET "$API_URL" -H "Authorization: Bearer $TOKEN" -H "accept: application/json")

  if [[ "$DEBUG" == true ]]; then
    echo "Request : curl -k -s -X GET \"$API_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"accept: application/json\""
    echo "Raw JSON :"
    echo "$response"
    echo
  fi

  fans=$(echo "$response" | jq -c '.fans[] | {ref: .fanRef, status: .status}')

  critical_found=false
  output=""
  while IFS= read -r fan; do
    ref=$(echo "$fan" | jq -r '.ref')
    status=$(echo "$fan" | jq -r '.status')

    if [[ "$status" != "optimal" ]]; then
      critical_found=true
      output+="CRITICAL: Fan $ref is in status $status\n"
    fi
  done <<< "$fans"

  if $critical_found; then
    echo -e "$output"
    exit 2
  else
    fan_count=$(echo "$fans" | wc -l)
    echo "OK: All $fan_count fans are optimal."
    exit 0
  fi
fi

if [[ "$MODE" == "cputemp" ]]; then
  if [[ -z "$WARNING" ]]; then
    echo "Error : missing parameter --warning"
    exit 1
  fi
  if [[ -z "$CRITICAL" ]]; then
    echo "Error : missing parameter --critical"
    exit 1
  fi
  # Get data from API
  API_URL="https://$HOSTNAME/devmgr/v2/storage-systems/1/diagnostic-data/power-input-data"
  response=$(curl -k -s -X GET "$API_URL" -H "Authorization: Bearer $TOKEN" -H "accept: application/json")

  if [[ "$DEBUG" == true ]]; then
    echo "Request : curl -k -s -X GET \"$API_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"accept: application/json\""
    echo "Raw JSON :"
    echo "$response"
    echo
  fi

  cpu_temps=$(echo "$response" | jq -r '.enclosureTemperatureInfo.thermalSensorInfoData[] | select(.label == "CPU") | .currentTempInCelsius')
  max_temp=$(get_max_temp "$cpu_temps")
  if (( max_temp >= CRITICAL )); then
    echo "CRITICAL: CPU temperature $max_temp°C is over critical limit ($CRITICAL°C)."
    exit 2
  elif (( max_temp >= WARNING )); then
    echo "WARNING: CPU temperature $max_temp°C is over warning limit ($WARNING°C)."
    exit 1
  fi
  echo "OK: CPU temperature ($max_temp°C) is fine."
  exit 0
fi

if [[ "$MODE" == "hddtemp" ]]; then
  if [[ -z "$WARNING" ]]; then
    echo "Error : missing parameter --warning"
    exit 1
  fi
  if [[ -z "$CRITICAL" ]]; then
    echo "Error : missing parameter --critical"
    exit 1
  fi
  # Get data from API
  API_URL="https://$HOSTNAME/devmgr/v2/storage-systems/1/diagnostic-data/power-input-data"
  response=$(curl -k -s -X GET "$API_URL" -H "Authorization: Bearer $TOKEN" -H "accept: application/json")

  if [[ "$DEBUG" == true ]]; then
    echo "Request : curl -k -s -X GET \"$API_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"accept: application/json\""
    echo "Raw JSON :"
    echo "$response"
    echo
  fi

  hdd_temps=$(echo "$response" | jq -r '.driveTemperatureInfo.driveTemperatureInformationData[] | .currentTempInCelsius')
  hdd_count=$(echo "$response" | jq -r '.driveTemperatureInfo.driveTemperatureInformationData | length')
  max_temp=$(get_max_temp "$hdd_temps")
  if (( max_temp >= CRITICAL )); then
    echo "CRITICAL: HDD temperature $max_temp°C is over critical limit ($CRITICAL°C)."
    exit 2
  elif (( max_temp >= WARNING )); then
    echo "WARNING: HDD temperature $max_temp°C is over warning limit ($WARNING°C)."
    exit 1
  fi
  echo "OK: Highest temp of $hdd_count HDD is ($max_temp°C), this is fine."
  exit 0
fi

if [[ "$MODE" == "inlettemp" ]]; then
  if [[ -z "$WARNING" ]]; then
    echo "Error : missing parameter --warning"
    exit 1
  fi
  if [[ -z "$CRITICAL" ]]; then
    echo "Error : missing parameter --critical"
    exit 1
  fi
  # Get data from API
  API_URL="https://$HOSTNAME/devmgr/v2/storage-systems/1/diagnostic-data/power-input-data"
  response=$(curl -k -s -X GET "$API_URL" -H "Authorization: Bearer $TOKEN" -H "accept: application/json")

  if [[ "$DEBUG" == true ]]; then
    echo "Request : curl -k -s -X GET \"$API_URL\" -H \"Authorization: Bearer $TOKEN\" -H \"accept: application/json\""
    echo "Raw JSON :"
    echo "$response"
    echo
  fi

  # I removed 2 id of Inlet temp because they sucks (127°C, not real)
  inlet_temps=$(echo "$response" | jq -r '.enclosureTemperatureInfo.thermalSensorInfoData[] | select(.label == "inlet" and (.id != "0B00000000000000000002000000000000000000" and .id != "0B00000000000000000004000000000000000000")) | .currentTempInCelsius')
  max_temp=$(get_max_temp "$inlet_temps")
  if (( max_temp >= CRITICAL )); then
    echo "CRITICAL: Inlet temperature $max_temp°C is over critical limit ($CRITICAL°C)."
    exit 2
  elif (( max_temp >= WARNING )); then
    echo "WARNING: Inlet temperature $max_temp°C is over warning limit ($WARNING°C)."
    exit 1
  fi
  echo "OK: Inlet temperature ($max_temp°C) is fine."
  exit 0
fi

# If mode not recognized
echo "Error : Unknown parameter : \"$MODE\""
show_help
exit 1
