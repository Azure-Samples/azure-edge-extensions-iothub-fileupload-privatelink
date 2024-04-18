# Setting up Azure IoT Hub File Upload to Azure Storage through Private Endpoint

How to enable Azure IoT Hub's file upload functionality through an Azure Storage only allowing private connections.

The file upload functionality provided by Azure IoT Hub serves as a secure bridge to the Azure Storage account, eliminating the need for IoT client devices to rely on external custom services for secure connections to the Storage account. For a comprehensive understanding of this feature, refer to the official  [Azure IoT Hub file upload overview](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-file-upload).

This repo offers guidance on securing Azure Storage account through a private endpoint while still allowing IoT Hub to interact with it securely, as well as allowing client IoT devices to reach the account through a gateway (Application Gateway and optionally Azure Firewall). With this approach the Storage account no longer allows public Internet access, which is a common requirement in enterprise deployments.

## Features

This project provides different options for configuring Azure IoT Hub File upload to a Storage private endpoint:

* [Documentation](./docs/doc-iothub-storage-private.md) with guidance an details on how you can accomplish this configuration in a Hub-Spoke network topology, leveraging Application Gateway, and Azure Firewall for traffic inspection
* Quickstart: Azure CLI based step-by-step scripts with a simplified setup (single Virtual Network & Resource Group) and sample client app
<!-- * Terraform IaC to provision and configure Hub-Spoke network topology with all components -->

## Getting Started

### Prerequisites

* Azure subscription
* Azure CLI
* Visual Studio Code
* OpenSSL CLI
* Bash terminal, on Windows you can use WSL
* .NET SDK 8 (if you wish to run the client and server samples for file upload)
* DNS provider if you wish to test HTTPS with your custom domain, and SSL Certificate for your custom domain

> [!TIP]
> Without a custom DNS and an SSL certificate available, you can still test the entire setup but the IoT client device portion of this quickstart will not be completed.

### Quickstart

This quickstart provides instructions on how to set up Azure IoT Hub's file upload functionality through an Azure Storage account that only allows private connections, through step-by-step scripts. The scripts deploy and configure a simplified set of Azure resources to showcase Azure Storage with private endpoint, Application Gateway and Azure IoT Hub routing to Azure Storage. The Storage account disables any public Internet access and only accessible within the Virtual Network. In this quickstart there is no Azure Firewall for traffic inspection.
Finally, two sample .NET apps interact with the resources deployed to showcase the end to end data flows.

> [!WARNING]
> This sample currently generates self-signed certificate and key files on disk. This should be improved to leverage Azure Key Vault for securely storing and retrieving the password, certificate and key. Application Gateway supports retrieving an SSL certificate from a Key Vault account.

#### Setup

* Open a Bash terminal
* `git clone` this repo
* cd [repository name]
* Open the project in Visual Studio Code `code .` and open a Bash terminal.
* Log into your Azure account `az login [--tenant xxxx-xxx]` and set the default subscription `az account set -s <subscription>`
* Prepare required environment variables to run the deployment scripts. We create a file in the folder `./temp` which is excluded from Git. 

  * Run the below to create the file `./temp/envvars.sh`, for `LOCATION` you can choose any Azure region supporting IoT Hub and Application Gateway.

    ```bash
    if [ ! -d "./temp" ]; then
        mkdir ./temp
    fi
    >./temp/envvars.sh cat <<EOF
    # change the below set to match your environment based on Readme
    export TENANT_ID="xxx-xxxx-xxx-xxxx-xxxx"
    export CERT_PASSWORD="xxx"
    export LOCATION="westeurope"
    export PREFIX="xxx"
    export RESOURCE_GROUP="rg-xxx-xxx"
    EOF

    code ./temp/envvars.sh
    ```

  * The newly created `.sh` file should now open in Visual Studio Code.
  * Edit the values to your preference, ensure `TENANT_ID` corresponds to your Azure tenant.
  * For `PREFIX` use a short 5 character string that can be unique for the resource name composition.
  * Load the variables by running:

  ```bash
  source ./temp/envvars.sh
  ```

#### Azure Resources with Virtual Network, private Storage and Application Gateway

Deploy the Azure components for setting up Virtual Network, self-signed SSL certificate, Storage, Private Link, custom private DNS and Application Gateway configured to talk to the Storage account. This allows you to validate the flow before configuring Azure IoT Hub and client communication.

* From the root directory of this repo, run the first part of the deployment. The script will use the environment variables and build composed resource names by appending the `PREFIX` variable as Azure resource names.

```bash
./deploy/quickstart-agw-storage.sh
```

* It will take a few minutes to deploy all resources. Keep the terminal open and take note of some of the generated DNS entries.
* This scripts also uploads a `sample.txt` file to a Blob storage container and generates a SAS URI token for testing.
* From a bash terminal, try out a `CURL` command to the DNS of the Public IP address attached to the Application Gateway.

```bash
curl --insecure "<APP_GATEWAY_SASURI copied output>"
```

* Run the same command with the Blob Public URI printed out by the script `BLOB_SASURI` value. Verify this does not succeed since this Storage account is blocking direct Internet traffic.

* Configure your custom DNS and SSL certificate for end to end SSL encryption.

  * Ensure you create a `CNAME` or `A` Record pointing to the DNS of the Azure Public IP created above.
  * `CNAME` is the simpler approach and you can point it to the value output of the script in the form of `xxx.westeurope.cloudapp.azure.com`.
  * Create an SSL certificate for this domain, or ensure you have a valid wildcard domain.
  * In Azure Portal, open the resource group you configured in the variables, and go to **Application Gateway**.
  * In the Listeners, edit the `storageHttpsListener`.
  * Upload a new certificate by choosing **Create new** and configuring the `.PFX` file, certificate name and password.
  * Test the name resolution works for your CNAME record and directs to the Public IP address used by the application gateway
  * Finally, test the custom URL and SAS URI without `--insecure` option as end to end SSL is now configured. the CURL should now be successful.
  
```bash
curl https://<yourcustommappeddomain>/test/sample.txt?<SAS>
```

#### Azure IoT Hub deployment and configuration

Deploy Azure IoT Hub and configure service communication to Azure Storage for File upload functionality.

> [!TIP]
> If you don't have custom DNS and SSL setup completed, use a dummy value when calling the script.

* Run the following script to deploy and configure Azure IoT Hub and Storage. The names of the resources are identical to the first script and composed by the environment variables loaded upfront.

```bash
./deploy/quickstart-add-iothub.sh "<your_custom_dns>"
```

* The script will output a sample device connection string, and a service connect endpoint connection string. You will use these in the IoT client sample.

#### IoT Client sample

> [!WARNING]
> It is a prerequisite to have a valid DNS custom domain and associated SSL certificate configured for this part to work. If you don't have this requirement, we recommend you review the [sample code projects](./src/) and the flow to understand the process.

To validate a client device on public Internet can leverage file upload with a custom domain mapping, you will use two Terminal windows to run a client and a server .NET sample app.

Run the File Upload notifications server app

* In a new terminal `CD` into the directory `./src/ServerSideFileNotification/`.
* Build the .NET app: `dotnet build`
* Run the sample app and leave it running. You will need to pass in the Service connection string from the `./deploy/quickstart-add-iothub.sh` script.

```bash
dotnet run "<iot hub service connection string>"
```

* Leave this running.

Run the IoT Client sample app

* In a new bash terminal `CD` into the directory `./src/SampleIoTClientFileUpload/`.
* Prepare a `.env` file for the required variables:

```bash
>.env cat <<EOF
IOT_HUB_HOSTNAME="TODO.azure-devices.net"
IOT_HUB_CONNSTRING="TODO"
DEVICE_ID="myDeviceOne"
AUTH_TYPE="symmetric_key"
EOF
    
code .env
```

* Ensure you replace the variable contents based on values output by the IoT Hub creation script.
* Build the .NET app: `dotnet build`.
* Run the .NET client app: `dotnet run`.
* Review the upload is successful.
* Switch to the terminal running the server app and note the notification has arrived.

### Clean-up Azure resources

This quickstart deploys all Azure resources within a single resource group. It's enough to delete the resource group to clean-up all cloud resources. From the terminal where you ran the scripts:

```bash
az group delete --name $RESOURCE_GROUP
```

## Resources

* [Microsoft Learn | Upload files with IoT Hub](https://learn.microsoft.com/azure/iot-hub/iot-hub-devguide-file-upload)
* [Azure Architecture Center | Hub-spoke network topology in Azure](https://learn.microsoft.com/azure/architecture/networking/architecture/hub-spoke?tabs=cli)
* [Microsoft Learn | Configure Azure Storage firewalls and virtual networks](https://learn.microsoft.com/azure/storage/common/storage-network-security?tabs=azure-cli)
* [Using Azure Application Gateway to map custom domain names to Private Endpoint enabled PaaS services](https://techcommunity.microsoft.com/t5/azure-architecture-blog/using-azure-application-gateway-to-map-custom-domain-names-to/ba-p/4025898)
