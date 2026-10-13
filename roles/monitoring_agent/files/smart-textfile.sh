#!/bin/sh
# Managed by roles/monitoring_agent -- SMART metrics for Alloy's textfile collector.
# -n standby: never spin up a sleeping HDD just to read SMART.
out=/var/lib/alloy/textfile/smart.prom
tmp="$out.$$"

# No -d: --scan labels SATA disks "scsi", which hides their model and ATA
# attributes; letting smartctl auto-detect the type gets the full data.
smartctl --scan -j | jq -r '.devices[].name' | while read -r dev; do
  smartctl -j -a -n standby "$dev" | jq -r --arg dev "${dev#/dev/}" '
    def attr($id): (.ata_smart_attributes.table // [] | map(select(.id == $id)) | .[0].raw.value);
    (.nvme_smart_health_information_log // {}) as $n
    | (.ata_smart_attributes.table // [] | map(select(.id == 177 or .id == 231 or .id == 233)) | .[0].value) as $life
    | select(.model_name != null)
    | "smart_info{device=\"\($dev)\",model=\"\(.model_name)\",serial=\"\(.serial_number)\"} 1",
      ( [ ["healthy", (if .smart_status.passed == null then null elif .smart_status.passed then 1 else 0 end)],
          ["temperature_celsius", .temperature.current],
          ["power_on_hours", .power_on_time.hours],
          ["nvme_percentage_used", $n.percentage_used],
          ["nvme_available_spare_percent", $n.available_spare],
          ["nvme_critical_warning", $n.critical_warning],
          ["nvme_media_errors", $n.media_errors],
          ["nvme_unsafe_shutdowns", $n.unsafe_shutdowns],
          ["nvme_data_units_written", $n.data_units_written],
          ["ata_reallocated_sectors", attr(5)],
          ["ata_pending_sectors", attr(197)],
          ["ata_offline_uncorrectable", attr(198)],
          ["ata_crc_errors", attr(199)],
          ["ssd_life_used_percent", (if $life == null then null else 100 - $life end)]
        ] | .[] | select(.[1] != null) | "smart_\(.[0]){device=\"\($dev)\"} \(.[1])" )'
done > "$tmp"

# eMMC has no SMART; wear comes from sysfs. life_time holds two estimates
# (0x01 = 0-10% used ... 0x0a = 90-100%, 0x0b = exceeded), report the worse one
# as its upper bound. pre_eol_info: 1 normal, 2 warning (80%), 3 urgent (90%).
for d in /sys/class/block/mmcblk[0-9]/device; do
  [ -r "$d/life_time" ] || continue
  dev=$(basename "$(dirname "$d")")
  read -r a b < "$d/life_time"
  worst=$((a > b ? a : b))
  echo "smart_emmc_life_used_percent{device=\"$dev\"} $((worst * 10))" >> "$tmp"
  [ -r "$d/pre_eol_info" ] && echo "smart_emmc_pre_eol{device=\"$dev\"} $(($(cat "$d/pre_eol_info")))" >> "$tmp"
done

echo "smart_last_run_timestamp_seconds $(date +%s)" >> "$tmp"
mv "$tmp" "$out"
