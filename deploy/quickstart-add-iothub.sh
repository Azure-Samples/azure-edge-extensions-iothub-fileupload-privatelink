#! /bin/bash

set -e

if [ -z "$RESOURCE_GROUP" ]; then
    echo "RESOURCE_GROUP is not set"
    exit 1
fi
if [ -z "$PREFIX" ]; then
    echo "PREFIX is not set"
    exit 1
fi
if [ -z "$LOCATION" ]; then
    echo "LOCATION is not set"
    exit 1
fi

# check if the first argument is present and assign to storage_custom_dns
if [ -z "$1" ]; then
    echo "Storage custom DNS is not set"
    echo "Usage: $0 <storage_custom_dns>"
    exit 1
fi
storage_custom_dns=$1

iot_hub_name="iot-$PREFIX"
storage_account_name="st$PREFIX"

echo "Creating IoT Hub $iot_hub_name in $LOCATION"
# Create the IoT Hub
set +e
az iot hub create --name $iot_hub_name --resource-group $RESOURCE_GROUP --sku S1
if [ $? -ne 0 ]; then
    echo "Error creating IoT Hub $iot_hub_name - make sure the name is available"
    echo "Ensure your PREFIX is unique to generate a unique IoT Hub name"
    echo "Exiting..."
    exit 1
fi

set -e

echo "Assigning Managed Identity to Azure IoT Hub and Role for storage account"
# Create the Azure Iot Hub managed identity and assign role/scope for storage
storage_account_res_id=$(az storage account show --name $storage_account_name --resource-group $RESOURCE_GROUP --query id --output tsv)
az iot hub identity assign --name $iot_hub_name \
    --resource-group $RESOURCE_GROUP \
    --system-assigned --role "Storage Blob Data Contributor" \
    --scopes $storage_account_res_id

echo "Configuring Storage firewall to allow IoT Hub via Resource Instance Exception"
# Allow Resource Instance Exception
# Get the IoT Hub Resource ID
iot_hub_resource_id=$(az iot hub show --name $iot_hub_name --resource-group $RESOURCE_GROUP --query id --output tsv)
az storage account network-rule add \
    --resource-id $iot_hub_resource_id \
    --tenant-id $TENANT_ID \
    -g $RESOURCE_GROUP \
    --account-name $storage_account_name

# Wait a few minutes for the role assignment to propagate
echo "Waiting for role assignment to propagate...."
sleep 2m

echo "Configuring IoT Hub to use Storage Account for file upload"
storage_connection_string=$(az storage account show-connection-string --name $storage_account_name --resource-group $RESOURCE_GROUP --query connectionString --output tsv)
az iot hub update --name $iot_hub_name \
    --resource-group $RESOURCE_GROUP \
    --fileupload-notifications true \
    --fileupload-storage-auth-type identityBased \
    --fileupload-storage-connectionstring "$storage_connection_string" \
    --fileupload-storage-container-name iothubdrops \
    --fileupload-storage-identity [system] 

echo "Creating a device in the IoT Hub"
# Create a sample device
az iot hub device-identity create --hub-name $iot_hub_name --device-id myDeviceOne --resource-group $RESOURCE_GROUP

echo "Getting the connection strings"
# Get the connection strings
iot_device_connection_string=$(az iot hub device-identity connection-string show --device-id myDeviceOne --resource-group $RESOURCE_GROUP --hub-name $iot_hub_name --output tsv)
iot_service_connection_string=$(az iot hub connection-string show --hub-name $iot_hub_name --resource-group $RESOURCE_GROUP --policy-name service --output tsv)

echo "Updating the sample myDeviceOne with the custom Storage DNS"
# Update the Device Twin with a reference to the Storage public URI
az iot hub device-twin update -n $iot_hub_name --resource-group $RESOURCE_GROUP \
    -d myDeviceOne --desired "{\"storage\":{\"customdns\": \"${storage_custom_dns}\" } }"

echo "Done provisioning and configuring the IoT Hub and Storage Account"
echo "====================="
echo "Device connection string for the C# SampleIoTClientFileUpload: " + $iot_device_connection_string
echo "====================="
echo "Service connection string for the C# ServerSideFileNotification: " + $iot_service_connection_string
echo "====================="