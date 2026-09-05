#!/bin/bash
REMOTE_IP="{{ remote_ip }}"
BUS_ID_ZEGBEE="{{ bus_id_zigbee }}"
BUS_ID_ZWAVE="{{ bus_id_zwave }}"

# Check if the device is already attached
if sudo usbip port | grep -q "$BUS_ID_ZEGBEE"; then
    echo "Device $BUS_ID_ZEGBEE is already attached. Skipping re-attach."
else
    echo "Attempting to attach USB/IP device $BUS_ID_ZEGBEE from $REMOTE_IP"
    if sudo usbip attach -r "$REMOTE_IP" -b "$BUS_ID_ZEGBEE"; then
        echo "USB/IP device $BUS_ID_ZEGBEE attached successfully."
    else
        echo "USB/IP attach failed for $BUS_ID_ZEGBEE. Attempting to rebind..."
        echo "SSHing into $REMOTE_IP to rebind device."
        ssh user@$REMOTE_IP sudo usbip unbind --busid="$BUS_ID_ZEGBEE"
        ssh user@$REMOTE_IP sudo usbip bind --busid="$BUS_ID_ZEGBEE"
        sudo usbip attach -r "$REMOTE_IP" -b "$BUS_ID_ZEGBEE"
    fi
fi

# Check if the device is already attached
if sudo usbip port | grep -q "$BUS_ID_ZWAVE"; then
    echo "Device $BUS_ID_ZWAVE is already attached. Skipping re-attach."
    exit 0
fi

echo "Attempting to attach USB/IP device $BUS_ID_ZWAVE from $REMOTE_IP"
if sudo usbip attach -r "$REMOTE_IP" -b "$BUS_ID_ZWAVE"; then
    echo "USB/IP device $BUS_ID_ZWAVE attached successfully."
else
    echo "USB/IP attach failed for $BUS_ID_ZWAVE. Attempting to rebind..."
    echo "SSHing into $REMOTE_IP to rebind device."
    ssh user@$REMOTE_IP sudo usbip unbind --busid="$BUS_ID_ZWAVE"
    ssh user@$REMOTE_IP sudo usbip bind --busid="$BUS_ID_ZWAVE"
    sudo usbip attach -r "$REMOTE_IP" -b "$BUS_ID_ZWAVE"
fi