import Flutter
import UIKit
import AVKit
import BackgroundTasks

public class SwiftFlutterBackgroundServicePlugin: FlutterPluginAppLifeCycleDelegate, FlutterPlugin  {
    static var taskIndentifier = "dev.flutter.background.refresh"
    
    var foregroundEngine: FlutterEngine? = nil
    var mainChannel: FlutterMethodChannel? = nil
    var foregroundChannel: FlutterMethodChannel? = nil
    
    var tmpEngine: FlutterEngine? = nil
    var tmpChannel: FlutterMethodChannel? = nil
    var tmpCompletionHandler: ((UIBackgroundFetchResult) -> Void)? = nil
    
    private(set) lazy var _tmpTask: Any? = nil
    
    @available(iOS 13, *)
    weak open var tmpTask: BGAppRefreshTask? {
        get {
            return _tmpTask as? BGAppRefreshTask
        } set {
            _tmpTask = newValue
        }
    }
    
    public override func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) -> Bool {
        // execute callback handle
        
        tmpCompletionHandler = completionHandler
        self.beginFetch(isForeground: false)
        return true
    }
        
    public override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [AnyHashable : Any] = [:]) -> Bool {
        
        UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        
        if #available(iOS 13.0, *) {
            registerBackgroundTasks()
        }
        
        return true
    }
    
    public func applicationDidEnterBackground(_ application: UIApplication) {
        if #available(iOS 13.0, *){
            self.scheduleAppRefresh()
        }
    }
    
    @available(iOS 13.0, *)
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: SwiftFlutterBackgroundServicePlugin.taskIndentifier, using: nil) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }
    
    @available(iOS 13.0, *)
    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: SwiftFlutterBackgroundServicePlugin.taskIndentifier)
       request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
            
       do {
          try BGTaskScheduler.shared.submit(request)
       } catch {
          print("Could not schedule app refresh: \(error)")
       }
    }
    
    @available(iOS 13.0, *)
    func handleAppRefresh(task: BGAppRefreshTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
            self.tmpEngine?.destroyContext()
            self.tmpEngine = nil
            self.tmpTask = nil
            self.tmpChannel = nil
        }
        
        scheduleAppRefresh()
        
        self.tmpTask = task
        DispatchQueue.main.async {
            self.beginFetch(isForeground: false)
        }
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "id.flutter/background_service_ios",
            binaryMessenger: registrar.messenger(),
            codec: FlutterJSONMethodCodec())
        
        let instance = SwiftFlutterBackgroundServicePlugin()
        instance.mainChannel = channel
        
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }
    
    private func autoStart(isForeground: Bool) {
        let defaults = UserDefaults.standard
        let autoStart = defaults.bool(forKey: "auto_start")
        if (autoStart) {
            self.beginFetch(isForeground: isForeground)
        }
    }
    
    private func handleBackgroundMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "getForegroundHandler") {
            let defaults = UserDefaults.standard
            let callbackHandle = defaults.object(forKey: "foreground_callback_handle") as? Int64
            result(callbackHandle)
            return
        }
        
        if (call.method == "getBackgroundHandler") {
            let defaults = UserDefaults.standard
            let callbackHandle = defaults.object(forKey: "background_callback_handle") as? Int64
            result(callbackHandle)
            return
        }
        
        if (call.method == "setBackgroundFetchResult" && tmpCompletionHandler != nil) {
            let result = call.arguments as? Bool ?? false
            
            if (result) {
                self.tmpCompletionHandler?(.newData)

                if #available(iOS 13.0, *) {
                    self.tmpTask?.setTaskCompleted(success: true)
                }
            } else {
                self.tmpCompletionHandler?(.noData)

                if #available(iOS 13.0, *) {
                    self.tmpTask?.setTaskCompleted(success: false)
                }
            }
            
            if (self.tmpEngine != nil) {
                self.tmpEngine!.destroyContext()
                self.tmpEngine = nil
                self.tmpChannel = nil

                if #available(iOS 13.0, *) {
                    self.tmpTask = nil
                }
            }
        }
        
        if (call.method == "sendData") {
            if (self.mainChannel != nil) {
                self.mainChannel?.invokeMethod("onReceiveData", arguments: call.arguments)
            }
            
            result(true);
            return;
        }
        
        if (call.method == "stopService") {
            self.foregroundEngine?.destroyContext();
            self.foregroundEngine = nil;
            result(true);
            return;
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if (call.method == "configure") {
            let args = call.arguments as? Dictionary<String, Any>
            let foregroundCallbackHandleID = args?["foreground_handle"] as? NSNumber
            let backgroundCallbackHandleID = args?["background_handle"] as? NSNumber
            let autoStart = args?["auto_start"] as? Bool
            
            let defaults = UserDefaults.standard
            defaults.set(foregroundCallbackHandleID?.int64Value, forKey: "foreground_callback_handle")
            defaults.set(backgroundCallbackHandleID?.int64Value, forKey: "background_callback_handle")
            defaults.set(autoStart, forKey: "auto_start")
            
            self.autoStart(isForeground: true)
            
            result(true)
            return
        }
        
        if (call.method == "start") {
            self.beginFetch(isForeground: true)
            result(true)
        }
        
        if (call.method == "sendData") {
            if (self.foregroundChannel != nil) {
                self.foregroundChannel?.invokeMethod("onReceiveData", arguments: call.arguments)
            }
            
            result(true);
        }
                
        if (call.method == "isServiceRunning") {
            let value = self.foregroundEngine != nil;
            result(value);
            return;
        }
    }
    
    // isForeground will be false if this method is executed by background fetch.
    private func beginFetch(isForeground: Bool) {
        if (isForeground && self.foregroundEngine != nil) {
            return
        }
        
        if (!isForeground && self.tmpEngine != nil) {
            self.tmpEngine?.destroyContext()
        }
        
        let entrypointName = isForeground ? "foregroundEntrypoint" : "backgroundEntrypoint"
        let uri = "package:flutter_background_service_ios/flutter_background_service_ios.dart"
        
        let backgroundEngine = FlutterEngine(name: "FlutterService")
        let isRunning = backgroundEngine.run(withEntrypoint: entrypointName, libraryURI: uri)
        
        if (isRunning) {
            FlutterBackgroundServicePlugin.register(backgroundEngine)
            
            let binaryMessenger = backgroundEngine.binaryMessenger
            let backgroundChannel = FlutterMethodChannel(name: "id.flutter/background_service_ios_bg", binaryMessenger: binaryMessenger, codec: FlutterJSONMethodCodec())
            
            backgroundChannel.setMethodCallHandler(self.handleBackgroundMethodCall)
            
            if (isForeground) {
                self.foregroundEngine = backgroundEngine
                self.foregroundChannel = backgroundChannel
            } else {
                self.tmpEngine = backgroundEngine
                self.tmpChannel = backgroundChannel
            }
        }
        
    }
}
