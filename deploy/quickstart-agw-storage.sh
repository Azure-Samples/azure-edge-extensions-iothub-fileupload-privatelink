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
if [ -z "$TENANT_ID" ]; then
    echo "TENANT_ID is not set"
    exit 1
fi
if [ -z "$CERT_PASSWORD" ]; then
    echo "CERT_PASSWORD is not set"
    exit 1
fi

storage_account_name="st$PREFIX"
vnet_name="vnet-$PREFIX"
app_gateway_name="gw-$PREFIX"
ip_stat_name_gateway="ip-gw-$PREFIX"
iprange_vnet="172.18.0.0/16"
subnet_name_gateway="subnet-gw-$PREFIX"
subnet_iprange_gateway="172.18.2.0/24"
subnet_name_private_link="subnet-pe-$PREFIX"
subnet_iprange_private_link="172.18.1.0/24"
private_link_name="pe-$PREFIX"
public_ip_gw="pip-$PREFIX"
dns_label="mydomain-$PREFIX"

if [ ! -d "./temp" ]; then
    mkdir ./temp
fi
commonNameFormat="/CN"
if [[ "$OSTYPE" == "msys" ]]; then
    commonNameFormat="//CN"
fi

echo "Starting provisioning of VNET, Storage, App gateway, DNS private records"

# Check if Storage acocunt name is available
if [ $(az storage account check-name --name $storage_account_name --query nameAvailable) == "false" ]; then
    echo "Storage account name $storage_account_name is not available, please adapt your PREFIX variable"
    exit 1
fi

echo "Creating Resource Group $RESOURCE_GROUP in $LOCATION"
# Create the Resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

echo "Creating self-signed test certificate"
# Generate a self-signed cert and PFX for testing without custom DNS
openssl genrsa -out ./temp/sample_privateKey.key 2048
openssl req -x509 -sha256 -nodes -days 365 -key ./temp/sample_privateKey.key -out ./temp/sample_appgwcert.crt --passout pass:$CERT_PASSWORD -subj "$commonNameFormat=$dns_label"
openssl pkcs12 -export -out ./temp/sample_appgwcert.pfx -inkey ./temp/sample_privateKey.key -in ./temp/sample_appgwcert.crt --passin pass:$CERT_PASSWORD --passout pass:$CERT_PASSWORD

echo "Creating Public IP for App Gateway"
az network public-ip create \
  --resource-group $RESOURCE_GROUP \
  --name $public_ip_gw \
  --allocation-method Static \
  --sku Standard \
  --location $LOCATION

echo "Creating Application Gateway and VNET"
# subnet_resource_id=$(az network vnet subnet show --name $subnet_name_gateway --vnet-name $vnet_name --resource-group $RESOURCE_GROUP --query id --output tsv)
# Using single command to create VNET & subnet due to some AZ CLI/API conflict which deletes the existing subnet
az network application-gateway create --name $app_gateway_name \
    --location $LOCATION \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $vnet_name \
    --subnet $subnet_name_gateway \
    --subnet-address-prefix $subnet_iprange_gateway \
    --vnet-address-prefix $iprange_vnet \
    --max-capacity 2 --sku Standard_v2 --min-capacity 0 \
    --http-settings-cookie-based-affinity Disabled \
    --frontend-port 80 \
    --http-settings-port 443 \
    --http-settings-protocol Https \
    --priority 300 \
    --public-ip-address $public_ip_gw

az network vnet subnet create --name $subnet_name_private_link \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $vnet_name \
    --address-prefixes $subnet_iprange_private_link

az network public-ip update --resource-group $RESOURCE_GROUP --name $public_ip_gw --dns-name $dns_label

ip_dns_fqdn=$(az network public-ip show --resource-group $RESOURCE_GROUP --name $public_ip_gw --query dnsSettings.fqdn --output tsv)
echo "Public IP FQDN: $ip_dns_fqdn"

echo "Creating NSG and allow incoming 443 traffic"
# Create NSG to allow incoming 443, and GatewayManager traffic to the Public IP
az network nsg create --name nsg-$PREFIX --resource-group $RESOURCE_GROUP
# TODO CHECK IF it's possible to allow only to the IP address static
az network nsg rule create --name Allow-Web --nsg-name nsg-$PREFIX --resource-group $RESOURCE_GROUP \
    --priority 1000 --direction Inbound --source-address-prefixes '*' --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 80 443 --access Allow --protocol Tcp
# allow GatewayManager rule
az network nsg rule create --name AllowGatewayManager --nsg-name nsg-$PREFIX --resource-group $RESOURCE_GROUP \
    --priority 2702 --direction Inbound --source-address-prefixes GatewayManager --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 65200-65535 --access Allow --protocol '*'

# Assign subnets to NSG
az network vnet subnet update --name $subnet_name_gateway --vnet-name $vnet_name --resource-group $RESOURCE_GROUP --network-security-group nsg-$PREFIX
az network vnet subnet update --name $subnet_name_private_link --vnet-name $vnet_name --resource-group $RESOURCE_GROUP --network-security-group nsg-$PREFIX

echo "Creating Storage account $storage_account_name"
# create storage account
az storage account create --name $storage_account_name --resource-group $RESOURCE_GROUP \
    --location $LOCATION --sku Standard_LRS \
    --https-only true --allow-blob-public-access false

echo "Uploading sample.txt test file to storage account"
az storage container create --name test --account-name $storage_account_name
az storage blob upload --container-name test --file sample.txt --name sample.txt --account-name $storage_account_name
# Create SAS token for the storage account file sample.txt
expiry=$(date -u -d "1 month" '+%Y-%m-%dT%H:%MZ')
sas_token=$(az storage blob generate-sas --account-name $storage_account_name --container-name test --name sample.txt --permissions r --expiry $expiry --output tsv)

echo "Retrieving Storage account endpoint"
# Get the blob endoint FQDN
storage_blob_endpoint=$(az storage account show --name $storage_account_name --resource-group $RESOURCE_GROUP --query primaryEndpoints.blob --output tsv)
blob_fqdn=$(echo "$storage_blob_endpoint" | sed 's|^https*://||' | sed 's:/*$::')
storage_account_res_id=$(az storage account show --name $storage_account_name --resource-group $RESOURCE_GROUP --query id --output tsv)

# Public URL
sas_public_uri=$(echo "${storage_blob_endpoint}test/sample.txt?$sas_token")
# App gateway enabled URL:
cloudapp_uri="https://$ip_dns_fqdn/test/sample.txt?$sas_token"

echo "Disable public access to the storage account"
# Disable public network access
az storage account update --name $storage_account_name --resource-group $RESOURCE_GROUP --default-action Deny

echo "Creating Private Endpoint for the Storage account"
# Create the private endpoint
az network private-endpoint create \
    --name $private_link_name \
    --connection-name $private_link_name-conn \
    --location $LOCATION \
    --resource-group $RESOURCE_GROUP \
    --vnet-name $vnet_name \
    --subnet $subnet_name_private_link \
    --private-connection-resource-id $storage_account_res_id \
    --ip-config name=ipconfig-1 group-id=blob member-name=blob private-ip-address=172.18.1.10 \
    --group-id blob

echo "Creating Private DNS Zone for the Storage account"
# Create the private DNS zone
az network private-dns zone create --name "privatelink.blob.core.windows.net" --resource-group $RESOURCE_GROUP

echo "Creating Private DNS Link for the Storage account"
az network private-endpoint dns-zone-group create --resource-group  $RESOURCE_GROUP \
    --endpoint-name $private_link_name \
    --name zone-group \
    --private-dns-zone "privatelink.blob.core.windows.net" \
    --zone-name blobzone

echo "Creating DNS private link for the Vnet"
az network private-dns link vnet create --resource-group $RESOURCE_GROUP \
     --zone-name "privatelink.blob.core.windows.net" \
     --name dns-blob-link \
     --virtual-network $vnet_name --registration-enabled false

echo "Creating backend pool for App Gateway"
az network application-gateway address-pool create \
  --gateway-name $app_gateway_name \
  --resource-group $RESOURCE_GROUP \
  --name storagePool \
  --servers $blob_fqdn

echo "Creating frontend port for App Gateway"
az network application-gateway frontend-port create --port 443 \
    --gateway-name $app_gateway_name \
    --resource-group $RESOURCE_GROUP \
    --name httpsPort

echo "Creating sample certificate for App Gateway"
# create SSL cert
az network application-gateway ssl-cert create \
  --gateway-name $app_gateway_name \
  --resource-group $RESOURCE_GROUP \
  --name appGatewaySslCert \
  --cert-file ./temp/sample_appgwcert.pfx \
  --cert-password $CERT_PASSWORD

echo "Creating listener for App Gateway"
# listener
az network application-gateway http-listener create \
  --name storageHttpsListener \
  --frontend-ip appGatewayFrontendIP \
  --frontend-port httpsPort \
  --resource-group $RESOURCE_GROUP \
  --gateway-name $app_gateway_name \
  --ssl-cert appGatewaySslCert

echo "Creating backend settings for App Gateway"
az network application-gateway http-settings create \
    --gateway-name $app_gateway_name \
    --name httpsBackendSettings \
    --resource-group $RESOURCE_GROUP \
    --port 443 \
    --protocol Https \
    --host-name-from-backend-pool true \
    --cookie-based-affinity Disabled \
    --timeout 30

echo "Creating routing rule for App Gateway"
az network application-gateway rule create \
  --gateway-name $app_gateway_name \
  --name storageRule \
  --resource-group $RESOURCE_GROUP \
  --http-listener storageHttpsListener \
  --http-settings httpsBackendSettings \
  --rule-type Basic \
  --address-pool storagePool \
  --priority 200

echo "Creating custom probe for App Gateway"
# Create probe
az network application-gateway probe create \
  --gateway-name $app_gateway_name \
  --name storageProbe \
  --resource-group $RESOURCE_GROUP \
  --protocol https \
  --host-name-from-http-settings true \
  --port 443 \
  --match-status-codes 200-400 \
  --path "/"

echo "Updating backend settings to use the custom probe"
# Update the backend settings to use the custom probe
az network application-gateway http-settings update \
    --gateway-name $app_gateway_name \
    --name httpsBackendSettings \
    --resource-group $RESOURCE_GROUP \
    --probe storageProbe

echo "Deleting Application Gateway rule1 and backend settings created by CLI initial command"
# Delete the default rule1 created by CLI initial command
az network application-gateway rule delete \
  --gateway-name $app_gateway_name \
  --name rule1 \
  --resource-group $RESOURCE_GROUP

az network application-gateway http-settings delete \
  --gateway-name $app_gateway_name \
  --name appGatewayBackendHttpSettings \
  --resource-group $RESOURCE_GROUP

az network application-gateway http-listener delete \
  --gateway-name $app_gateway_name \
  --name appGatewayHttpListener \
  --resource-group $RESOURCE_GROUP

az network application-gateway address-pool delete \
    --gateway-name $app_gateway_name \
    --name appGatewayBackendPool \
    --resource-group $RESOURCE_GROUP

echo "Done provisioning VNET, Storage, App gateway, DNS private records"
echo "====================="
echo "App Gateway is now handling incoming traffic to private Storage account."
echo "A SAS token has been generated for the file sample.txt"
echo "====================="
echo "BLOB_SASURI: $sas_public_uri"
echo "====================="
echo "To use the SAS token with the App Gateway URL:"
echo "====================="
echo "APP_GATEWAY_SASURI: $cloudapp_uri"
echo "====================="
echo "To use your own custom domain: add a CNAME record to $ip_dns_fqdn"
echo "====================="