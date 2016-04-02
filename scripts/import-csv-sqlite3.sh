#!/bin/bash

cd ~/zoom-it-data-git

echo "===> Prepare fresh output directories"
rm -rf output
mkdir -p output/{group1,group2}

echo "===> Split files based on CSV (TSV) header line"
csplit -n 4 -f './output/split-ContentInfo-' -k ~/zoom-it-data-git/ContentInfo.txt '/^#Attributes PartitionKey/' '{9999}' &> /dev/null

# Print unique header lines:
# cat  output/split-ContentInfo-* | grep '^#Attributes' | sort | uniq
# > #Attributes PartitionKey  RowKey  Timestamp AbuseLevel  AttributionLink AttributionText Blob  Error Id  Mime  NumAbuseReports Progress  Size  Stage Title Type  Url Version
# > #Attributes PartitionKey  RowKey  Timestamp AbuseLevel  Blob  Error Id  Mime  NumAbuseReports Progress  Size  Stage Type  Url Version AttributionLink AttributionText Title

echo "===> Group files by CSV (TSV) header line type"
group1=$(grep --files-with-matches -R '^#Attributes PartitionKey\tRowKey\tTimestamp\tAbuseLevel\tAttributionLink\tAttributionText\tBlob\tError\tId\tMime\tNumAbuseReports\tProgress\tSize\tStage\tTitle\tType\tUrl\tVersion\r$' output)
group2=$(grep --files-with-matches -R '^#Attributes PartitionKey\tRowKey\tTimestamp\tAbuseLevel\tBlob\tError\tId\tMime\tNumAbuseReports\tProgress\tSize\tStage\tType\tUrl\tVersion\tAttributionLink\tAttributionText\tTitle\r$' output)
mv $group1 output/group1
mv $group2 output/group2

cd - > /dev/null
