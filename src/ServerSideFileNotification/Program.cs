using Microsoft.Azure.Devices;

if (args.Length < 1)
{
    Console.WriteLine("Please provide a 'Service' connection string as the first argument");
    Console.WriteLine("Call this app as follows: dotnet run <iot hub Service connection string>");
    return;
}
string connectionString = args[0];

Console.WriteLine("Receive file upload notifications\n");
ServiceClient serviceClient = ServiceClient.CreateFromConnectionString(connectionString);
ReceiveFileUploadNotificationAsync(serviceClient);
Console.WriteLine("Press any key to exit\n");
Console.ReadLine();

// define the callback for the file upload notification
async static void ReceiveFileUploadNotificationAsync(object serviceContext)
{
    var serviceClient = (ServiceClient)serviceContext;
    var notificationReceiver = serviceClient.GetFileNotificationReceiver();
    Console.WriteLine("\nReceiving file upload notification from service");
    var cancellationToken = new CancellationTokenSource().Token;
    while (true)
    {
        var fileUploadNotification = await notificationReceiver.ReceiveAsync(cancellationToken);
        if (fileUploadNotification == null) continue;
        Console.ForegroundColor = ConsoleColor.Yellow;
        Console.WriteLine("Received file upload notification: {0}",
          string.Join(", ", fileUploadNotification.BlobName));
        Console.ResetColor();
        await notificationReceiver.CompleteAsync(fileUploadNotification, cancellationToken);
    }
}