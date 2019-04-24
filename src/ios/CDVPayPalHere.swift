import PayPalRetailSDK

@objc(CDVPayPalHere) class CDVPayPalHere : CDVPlugin {
  var merchantInitialized : Bool = false
  var readerConnected: Bool = false
  
  // MARK: - Cordova Interface
  
  @objc(initializeMerchantCDV:) func initializeMerchantCDV(_ command: CDVInvokedUrlCommand) {
    commandDelegate.run {
      let accessToken = command.arguments[0] as? String ?? ""
      let refreshUrl = command.arguments[1] as? String ?? ""
      let environment = command.arguments[2] as? String ?? ""
      let referrerCode = command.arguments[3] as? String ?? ""
      
      self.initializeMerchant(
        accessToken: accessToken,
        refreshUrl: refreshUrl,
        environment: environment,
        referrerCode: referrerCode,
        onSuccess: self.getCordovaSuccessCallback(command),
        onError: self.getCordovaErrorCallback(command)
      )
    }
  }
  
  @objc(connectToReaderCDV:) func connectToReaderCDV(_ command: CDVInvokedUrlCommand) {
    commandDelegate.run {
      self.connectToReader(
        onSuccess: self.getCordovaSuccessCallback(command),
        onError: self.getCordovaErrorCallback(command)
      )
    }
  }
  
  @objc(searchAndConnectToReaderCDV:) func searchAndConnectToReaderCDV(_ command: CDVInvokedUrlCommand) {
    commandDelegate.run {
      self.searchAndConnectToReader(
        onSuccess: self.getCordovaSuccessCallback(command),
        onError: self.getCordovaErrorCallback(command)
      )
    }
  }
  
  @objc(takePaymentCDV:) func takePaymentCDV(_ command: CDVInvokedUrlCommand) {
    commandDelegate.run {
      let currencyCode = command.arguments[0] as? String ?? "USD"
      let total = NSDecimalNumber(decimal: ((command.arguments[1] as? NSNumber ?? 0)?.decimalValue)!)
      
      self.takePayment(
        currencyCode: currencyCode,
        total: total,
        onSuccess: self.getCordovaSuccessCallback(command),
        onError: self.getCordovaErrorCallback(command)
      )
    }
  }
  
  // MARK: - Swift Implementation
  
  func initializeMerchant(
    accessToken: String,
    refreshUrl: String,
    environment: String,
    referrerCode: String,
    onSuccess: @escaping (String) -> Void,
    onError: @escaping (String) -> Void
    )  {
    
    let hasEmptyValues: Bool = accessToken.isEmpty || refreshUrl.isEmpty || environment.isEmpty
    
    if hasEmptyValues {
      // this is needed because PayPalRetailSDK.initializeMerchant just doesn't ever call the callback
      // if any of the values are empty
      return onError("accessToken, refreshUrl, & environment arguments must not be empty")
    }
    
    self.log("INITIALIZE SDK START")
    PayPalRetailSDK.initializeSDK()
    self.log("INITIALIZE SDK SUCCESS")
    
    self.log("INITIALIZE MERCHANT START")
    let sdkCreds = SdkCredential(
      accessToken: accessToken,
      refreshUrl: refreshUrl,
      environment: environment
    )
    
    PayPalRetailSDK.initializeMerchant(withCredentials: sdkCreds) {[weak self] (error, merchant) in
      if let err = error {
        self?.logError(error: err, context: "INITIALIZE MERCHANT FAILED")
        return onError(err.message!)
      }
      
      guard let merchant = merchant else {
        return onError("No merchant returned from initialization")
      }
      
      merchant.referrerCode = referrerCode
      self?.log("INITIALIZE MERCHANT SUCCESS")
      self?.merchantInitialized = true
      onSuccess("Initialized")
    }
  }
  
  func checkForReaderUpdate(reader: PPRetailPaymentDevice?) {
    guard let pendingUpdate = reader?.pendingUpdate, pendingUpdate.isRequired == true else {
      self.log("Reader update not required at this time.")
      return
    }
    
    pendingUpdate.offer({[weak self] (error, updateComplete) in
      guard updateComplete else {
        self?.logError(error: error!, context: "READER UPDATE")
        return
      }
      
      self?.log("Reader update complete.")
    })
  }
  
  func connectToReader(
    onSuccess: @escaping (String) -> Void,
    onError: @escaping (String) -> Void) {
    
    self.log("CONNECT TO READER START")
    
    let deviceManager = PayPalRetailSDK.deviceManager()
    
    guard merchantInitialized else {
      onError("Merchant needs to be initialized before you can connect to a payment device.")
      return
    }
    
    deviceManager?.connect(toLastActiveReader: self.getConnectToReaderHandler(onSuccess: onSuccess, onError: onError))
  }
  
  func searchAndConnectToReader(
    onSuccess: @escaping (String) -> Void,
    onError: @escaping (String) -> Void) {
    
    self.log("CONNECT TO READER START")
    
    let deviceManager = PayPalRetailSDK.deviceManager()
    
    guard merchantInitialized else {
      onError("Merchant needs to be initialized before you can connect to a payment device.")
      return
    }
    
    deviceManager?.searchAndConnect(self.getConnectToReaderHandler(onSuccess: onSuccess, onError: onError))
  }
  
  func takePayment(
    currencyCode: String,
    total: NSDecimalNumber,
    onSuccess: @escaping (String) -> Void,
    onError: @escaping (String) -> Void) {
    
    self.log("TAKE PAYMENT START")
    
    guard merchantInitialized else {
      onError("Merchant needs to be initialized before you can take a payment.")
      return
    }
    
    guard readerConnected else {
      onError("A payment device must be connected before you can take a payment.")
      return
    }
    
    let unitPrice = NSDecimalNumber(value: max(total.doubleValue, 0))
    
    if unitPrice.decimalValue < 1.00 {
      return onError("Total price must be greater than 1.00")
    }
    
    let invoice: PPRetailInvoice?
    invoice = PPRetailInvoice.init(currencyCode: currencyCode)
    invoice!.addItem("Order", quantity: 1, unitPrice: unitPrice, itemId: 0, detailId: nil)
    
    PayPalRetailSDK.transactionManager().createTransaction(invoice, callback: { (error, context) in
      if let err = error {
        self.logError(error: err, context: "TAKE PAYMENT FAILED @ CREATE TRANSACTION")
        return onError(err.message ?? "")
      }
      
      self.log("TAKE PAYMENT - TRANSACTION CREATED")
      context?.setCompletedHandler(self.getCreateTransactionCompleteHandler(onSuccess: onSuccess, onError: onError))
      
      let paymentOptions = PPRetailTransactionBeginOptions()
      paymentOptions!.showPromptInCardReader = true
      paymentOptions!.showPromptInApp = true
      paymentOptions!.preferredFormFactors = []
      paymentOptions!.tippingOnReaderEnabled = false
      paymentOptions!.amountBasedTipping = false
      paymentOptions!.isAuthCapture = false
      
      context?.beginPayment(paymentOptions)
    })
  }
  
  // MARK: - Cordova Callbacks
  
  private func getCordovaSuccessCallback(_ command: CDVInvokedUrlCommand) -> (String) -> Void {
    return { (msg: String) in
      self.commandDelegate!.send(
        CDVPluginResult(status: CDVCommandStatus_OK, messageAs: msg),
        callbackId: command.callbackId
      )
    }
  }
  
  private func getCordovaErrorCallback(_ command: CDVInvokedUrlCommand) -> (String) -> Void {
    return { (msg: String) in
      self.commandDelegate!.send(
        CDVPluginResult(status: CDVCommandStatus_ERROR, messageAs: msg),
        callbackId: command.callbackId
      )
    }
  }
  
  // MARK: - Handlers
  
  private func getCreateTransactionCompleteHandler(
    onSuccess: @escaping (String) -> Void,
    onError: @escaping (String) -> Void) -> Optional<(Optional<PPRetailError>, Optional<PPRetailTransactionRecord>) -> ()> {
    
    return { (error, record) in
      var logJSON = "{}"
      
      if let tx = record {
        logJSON = self.getJSON([
          "transactionNumber": tx.transactionNumber ?? "",
          "invoiceId": tx.invoiceId ?? "",
          "authCode": tx.authCode ?? "",
          "transactionHandle": tx.transactionHandle ?? "",
          "responseCode": tx.responseCode ?? "",
          "correlationId": tx.correlationId ?? "",
          "captureId": tx.captureId ?? "",
          "error": (
            error != nil
              ? self.getJSONForError(error)
              : ""
          )
          ])
      } else {
        logJSON = self.getJSON([
          "error": self.getJSON(["message": "No transaction record found."])
          ])
      }
      
      if let err = error {
        self.logError(error: err, context: "TAKE PAYMENT FAILED @ COMPLETED HANDLER")
        self.log(logJSON)
        onError(logJSON)
        return
      }
      
      self.log("TAKE PAYMENT SUCCESS")
      onSuccess(logJSON)
    }
  }
  
  private func getConnectToReaderHandler(
    onSuccess: @escaping (String) -> Void,
    onError: @escaping (String) -> Void
    ) -> Optional<(Optional<PPRetailError>, Optional<PPRetailPaymentDevice>) -> ()> {
    return { (error, paymentDevice) in
      if let err = error {
        self.logError(error: err, context: "CONNECT TO READER FAILED")
        onError(err.message!)
        return
      }
      
      guard paymentDevice?.isConnected() == true else {
        self.log("CONNECT TO READER FAILED - PAYMENT DEVICE NOT CONNECTED")
        onError("A payment device is not connected.")
        return
      }
      
      let paymentDeviceId = paymentDevice?.id
      self.log("CONNECT TO READER SUCCESS")
      self.log("PAYMENT DEVICE ID: " + paymentDeviceId!)
      self.readerConnected = true
      self.checkForReaderUpdate(reader: paymentDevice)
      onSuccess("Payment device with ID " + paymentDeviceId! + " found.")
    }
  }
  
  // MARK: - Private
  
  private func log(_ msg: String) {
    print("[CDVPayPalHere] " + msg)
  }
  
  private func logError(error: PPRetailError, context: String) {
    self.log(context)
    self.log(self.getJSONForError(error))
  }
  
  private func getJSON (_ d: Dictionary<String, String>) -> String {
    var str = "{"
    for (k, v) in d {
      if (v.hasPrefix("{") || v.hasPrefix("[")) {
        str += "\"\(k)\":\(v),"
      } else {
        str += "\"\(k)\":\"\(v)\","
      }
    }
    
    str = String(str[..<str.index(before: str.endIndex)])
    
    str += "}"
    return str
  }
  
  private func getJSONForError (_ error: PPRetailError?) -> String {
    guard let error = error else {
      return self.getJSON([:])
    }
    
    return self.getJSON([
      "debugId": error.debugId ?? "",
      "code": error.code ?? "",
      "message": error.message ?? "",
      "developerMessage": error.developerMessage ?? ""
      ])
  }
}
