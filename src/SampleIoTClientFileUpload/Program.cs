// See https://aka.ms/new-console-template for more information
using System.Security.Cryptography.X509Certificates;
using dotenv.net;
using dotenv.net.Utilities;
using Microsoft.Azure.Devices.Client;
using Microsoft.Azure.Devices.Shared;
using Microsoft.Azure.Devices.Client.Transport;
using Microsoft.Extensions.Logging;
using Azure.Storage.Blobs.Specialized;
using Azure.Storage.Blobs.Models;

string _customStorageUri = "";

DotEnv.Load();

var loggerFactory = LoggerFactory.Create(builder => builder.AddConsole());
var logger = loggerFactory.CreateLogger<Program>();

logger.LogInformation("Starting app");

string iotHubConnectionString = EnvReader.GetStringValue("IOT_HUB_CONNSTRING");
string iotHubHostname = EnvReader.GetStringValue("IOT_HUB_HOSTNAME");
string deviceId = EnvReader.GetStringValue("DEVICE_ID");
string authenticationType = EnvReader.GetStringValue("AUTH_TYPE"); // "x509" or "symmetric_key"

logger.LogInformation("Auth type: {authenticationType}", authenticationType);

DeviceClient deviceClient;
if (authenticationType == "x509")
{
    string certificatePath = EnvReader.GetStringValue("CERTIFICATE_PATH");
    string certificatePassword = EnvReader.GetStringValue("CERTIFICATE_PASSWORD");
    var auth = new DeviceAuthenticationWithX509Certificate(deviceId, new X509Certificate2(certificatePath, certificatePassword));
    deviceClient = DeviceClient.Create(iotHubHostname, auth, TransportType.Mqtt);
}
else if (authenticationType == "symmetric_key")
{
    deviceClient = DeviceClient.CreateFromConnectionString(iotHubConnectionString, TransportType.Mqtt);
}
else
{
    throw new Exception("Invalid authentication type. Please specify 'x509' or 'symmetric_key'.");
}

// Open device client
await deviceClient.OpenAsync();

// Set up twin update callback
await deviceClient.SetDesiredPropertyUpdateCallbackAsync(OnDesiredPropertyChanged, null);
// Force loading desired properties from the service on startup
var twin = await deviceClient.GetTwinAsync();
await OnDesiredPropertyChanged(twin.Properties.Desired, deviceClient);

// Do a file upload
const string filePath = "testfile1.txt";
Console.WriteLine("File upload starting...");
await UploadFileAsync(filePath, deviceClient);

Console.WriteLine("Press any key to exit...");
Console.ReadKey();

// Close device client
await deviceClient.CloseAsync();

async Task UploadFileAsync(string filePath, DeviceClient deviceContext)
{
    using var fileStreamSource = new FileStream(filePath, FileMode.Open);
    var fileName = Path.GetFileName(fileStreamSource.Name);

    Console.WriteLine($"Uploading file {fileName}");

    var fileUploadSasUriRequest = new FileUploadSasUriRequest
    {
        BlobName = fileName
    };

    // Note: GetFileUploadSasUriAsync and CompleteFileUploadAsync will use HTTPS as protocol regardless of the DeviceClient protocol selection.
    Console.WriteLine("Getting SAS URI from IoT Hub to use when uploading the file...");
    FileUploadSasUriResponse sasUri = await deviceContext.GetFileUploadSasUriAsync(fileUploadSasUriRequest);
    Uri uploadUri = sasUri.GetBlobUri();

    Console.WriteLine($"Successfully got SAS URI ({uploadUri}) from IoT Hub");

    //parse the URI and replace the hostname with the custom one
    if (!string.IsNullOrEmpty(_customStorageUri))
    {
        var uriBuilder = new UriBuilder(uploadUri);
        uriBuilder.Host = _customStorageUri;
        uploadUri = uriBuilder.Uri;
    }
    Console.WriteLine($"New Blob URI: {uploadUri}");

    try
    {
        Console.WriteLine($"Uploading file {fileName} using the Azure Storage SDK and the retrieved SAS URI for authentication - overwriting the base hostname");

        var blockBlobClient = new BlockBlobClient(uploadUri);
        await blockBlobClient.UploadAsync(fileStreamSource, new BlobUploadOptions());
    }
    catch (Exception ex)
    {
        Console.WriteLine($"Failed to upload file to Azure Storage using the Azure Storage SDK due to {ex}");

        var failedFileUploadCompletionNotification = new FileUploadCompletionNotification
        {
            // Mandatory. Must be the same value as the correlation id returned in the sas uri response
            CorrelationId = sasUri.CorrelationId,

            // Mandatory. Will be present when service client receives this file upload notification
            IsSuccess = false,

            // Optional, user-defined status code. Will be present when service client receives this file upload notification
            StatusCode = 500,

            // Optional, user defined status description. Will be present when service client receives this file upload notification
            StatusDescription = ex.Message
        };

        await deviceContext.CompleteFileUploadAsync(failedFileUploadCompletionNotification);
        Console.WriteLine("Notified IoT Hub that the file upload failed and that the SAS URI can be freed");

        return;
    }

    Console.WriteLine("Successfully uploaded the file to Azure Storage");

    var successfulFileUploadCompletionNotification = new FileUploadCompletionNotification
    {
        // Mandatory. Must be the same value as the correlation id returned in the sas uri response
        CorrelationId = sasUri.CorrelationId,

        // Mandatory. Will be present when service client receives this file upload notification
        IsSuccess = true,

        // Optional, user defined status code. Will be present when service client receives this file upload notification
        StatusCode = 200,

        // Optional, user-defined status description. Will be present when service client receives this file upload notification
        StatusDescription = "Success"
    };

    await deviceContext.CompleteFileUploadAsync(successfulFileUploadCompletionNotification);
    Console.WriteLine("Notified IoT Hub that the file upload succeeded and that the SAS URI can be freed.");
}

async Task OnDesiredPropertyChanged(TwinCollection desiredProperties, object deviceContext)
{
    Console.WriteLine("Received device twin update:");
    Console.WriteLine(desiredProperties.ToJson());
    //todo get the property under storage/customdns
    _customStorageUri = (string)desiredProperties["storage"]["customdns"];
}