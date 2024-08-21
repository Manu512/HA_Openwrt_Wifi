#!/bin/ash

# Configurations
MQTT_HOST="mqtt.local"  # Remplacez par l'adresse IP de votre serveur MQTT
MQTT_PORT="1883"
MQTT_USER="tobeornot"  # Remplacez par votre nom d'utilisateur MQTT
MQTT_PASSWORD="vroom"  # Remplacez par votre mot de passe MQTT
TOPIC_PREFIX_DISCOVERY="homeassistant/sensor"  # Préfixe pour le discovery
TOPIC_PREFIX_DATA="openwrt/wifi"  # Préfixe pour les données
DHCP_LEASES_FILE="/mnt/sda1/tmp/dhcp.leases"  # Chemin personnalisé du fichier DHCP leases
DHCP_CONFIG_FILE="/etc/config/dhcp"  # Chemin du fichier de configuration DHCP

# Fonction pour formater les adresses MAC (remplacer ':' par '-' et convertir en majuscules pour le topic MQTT)
format_mac() {
    local mac; mac=$(echo "$1" | sed 's/:/-/g' | tr 'a-f' 'A-F')
    printf "%s" "$mac"
}

# Fonction pour normaliser une adresse MAC en minuscules pour comparaison dans le fichier DHCP leases
normalize_mac() {
    local mac; mac=$(echo "$1" | tr 'A-F' 'a-f')
    printf "%s" "$mac"
}

# Fonction pour convertir une MAC en majuscules
to_upper() {
    echo "$1" | tr 'a-f' 'A-F'
}

# Fonction pour rechercher le hostname dans /etc/config/dhcp
get_hostname_from_dhcp_config() {
    local mac; mac=$(to_upper "$1")

    # Trouver le bloc contenant la MAC recherchée
    local block; block=$(awk -v mac="$mac" '
        BEGIN { RS = ""; FS = "\n" }
        {
            for (i = 1; i <= NF; i++) {
                if (tolower($i) ~ tolower(mac)) {
                    print $0
                    exit
                }
            }
        }
    ' "$DHCP_CONFIG_FILE")

    # Si le bloc est trouvé, extraire le hostname
    if [ -n "$block" ]; then
        hostname=$(echo "$block" | grep -o "option name '[^']*'" | cut -d"'" -f2)
    fi

    # Si aucun hostname n'est trouvé, retourner "Unknown"
    if [ -z "$hostname" ]; then
        hostname="Unknown"
    fi

    printf "%s\n" "$hostname"
}

# Fonction pour trouver le hostname à partir de l'adresse MAC
get_hostname() {
    local mac; mac=$(normalize_mac "$1")
    local hostname; hostname=$(grep -i "$mac" "$DHCP_LEASES_FILE" | awk '{print $4}')

    if [ -z "$hostname" ]; then
        hostname=$(get_hostname_from_dhcp_config "$mac")
    fi

    if [ -z "$hostname" ]; then
        hostname="Unknown"
    fi

    printf "%s" "$hostname"
}

# Fonction pour publier via MQTT avec authentification
publish_mqtt() {
    local topic=$1
    local message=$2
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -u "$MQTT_USER" -P "$MQTT_PASSWORD" -t "$topic" -m "$message"
}

# Fonction pour évaluer la qualité du signal Wi-Fi
evaluate_signal_quality() {
    local signal=$1
    if [ "$signal" -ge -40 ]; then
        echo "Excellent"
    elif [ "$signal" -ge -50 ]; then
        echo "Tres Bon"
    elif [ "$signal" -ge -60 ]; then
        echo "Bon"
    elif [ "$signal" -ge -70 ]; then
        echo "Moyen"
    elif [ "$signal" -ge -80 ]; then
        echo "Mauvais"
    elif [ "$signal" -ge -90 ]; then
        echo "Faible"
    else
        echo "Nul"
    fi
}


# Fonction pour publier la configuration MQTT Discovery
publish_discovery_config() {
    local device_name=$1
    local mac=$2
    local sensor_type=$3
    local state_topic=$4
    local unit_of_measurement=$5
    local device_class=$6
    local icon=$7
    
    #Unique Id pour Signal Quality
    if [ "$sensor_type" = "Signal_Quality" ]; then 
        unique_id="${mac}-SiQ"
    else
        local unique_id="${mac}-${sensor_type:0:2}"
    fi 
    


    local config_topic="${TOPIC_PREFIX_DISCOVERY}/wifi_${mac}/${sensor_type}/config"
    local config_payload="{
        \"name\": \"${sensor_type}\",
        \"state_topic\": \"${state_topic}\",
        \"unique_id\": \"${unique_id}\",
        \"device\": {
            \"identifiers\": [\"wifi_${mac}\"],
            \"name\": \"${device_name}\",
            \"model\": \"WiFi Station\",
            \"manufacturer\": \"OpenWrt\"
        },
        \"force_update\": true"

    # Ajouter des champs optionnels
    if [ -n "$device_class" ]; then
        config_payload="${config_payload}, \"device_class\": \"${device_class}\""
    fi

    if [ -n "$unit_of_measurement" ]; then
        config_payload="${config_payload}, \"unit_of_measurement\": \"${unit_of_measurement}\""
    fi

    if [ -n "$icon" ]; then
        config_payload="${config_payload}, \"icon\": \"${icon}\""
    fi

    config_payload="${config_payload} }"

    publish_mqtt "$config_topic" "$config_payload"
}

# Fonction pour publier les états des capteurs
publish_sensor_state() {
    local raw_interface=$1
    local mac=$2
    local signal=$3
    local tx_bitrate=$4
    local rx_bitrate=$5
    local hostname=$6
    local mac_upper; mac_upper=$(format_mac "$mac")

    # Vérifie si le hostname est "Unknown"
    if [ "$hostname" = "Unknown" ]; then 
        hostname=$mac_upper
    fi

    local device_name="${hostname:-WiFi_${mac_upper}}"
    local base_topic="${TOPIC_PREFIX_DATA}/wifi_${mac_upper}"
    local signal_quality; signal_quality=$(evaluate_signal_quality "$signal")

    # Publier les états des capteurs
    publish_mqtt "${base_topic}/Signal" "$signal"
    publish_mqtt "${base_topic}/Signal_Quality" "$signal_quality"
    publish_mqtt "${base_topic}/MAC_Address" "$mac"
    publish_mqtt "${base_topic}/Interface" "$raw_interface"
    publish_mqtt "${base_topic}/TX_Bitrate" "$tx_bitrate"
    publish_mqtt "${base_topic}/RX_Bitrate" "$rx_bitrate"

    # Publier les configurations MQTT Discovery pour chaque capteur
    publish_discovery_config "$device_name" "$mac_upper" "Signal" "${base_topic}/Signal" "dBm" "signal_strength" "mdi:wifi"
    publish_discovery_config "$device_name" "$mac_upper" "Signal_Quality" "${base_topic}/Signal_Quality" "" "" "mdi:signal"
    publish_discovery_config "$device_name" "$mac_upper" "MAC_Address" "${base_topic}/MAC_Address" "" "" "mdi:barcode"
    publish_discovery_config "$device_name" "$mac_upper" "Interface" "${base_topic}/Interface" "" "" "mdi:access-point-network"
    publish_discovery_config "$device_name" "$mac_upper" "TX_Bitrate" "${base_topic}/TX_Bitrate" "Mbit/s" "data_rate" "mdi:speedometer"
    publish_discovery_config "$device_name" "$mac_upper" "RX_Bitrate" "${base_topic}/RX_Bitrate" "Mbit/s" "data_rate" "mdi:speedometer"
}

# Collecter les informations des clients Wi-Fi
collect_data() {
    local interface=$1
    local mac signal tx_bitrate rx_bitrate

    iw dev "$interface" station dump | while read -r line; do
        case "$line" in
            *Station*)
                mac=$(echo "$line" | awk '{print $2}')
                ;;
            *signal:*)
                signal=$(echo "$line" | awk '{print $2}')
                ;;
            *tx\ bitrate:*)
                tx_bitrate=$(echo "$line" | awk '{print $3}')
                ;;
            *rx\ bitrate:*)
                rx_bitrate=$(echo "$line" | awk '{print $3}')
                ;;
        esac

        # Vérifier si toutes les informations sont présentes
        if [ -n "$mac" ] && [ -n "$signal" ] && [ -n "$tx_bitrate" ] && [ -n "$rx_bitrate" ]; then
            local hostname; hostname=$(get_hostname "$mac")
            publish_sensor_state "$interface" "$mac" "$signal" "$tx_bitrate" "$rx_bitrate" "$hostname"
            mac="" signal="" tx_bitrate="" rx_bitrate=""
        fi
    done
}

# Appeler la fonction pour les interfaces Wi-Fi
main() {
    collect_data "5G"
    collect_data "2.4G"
}

main
