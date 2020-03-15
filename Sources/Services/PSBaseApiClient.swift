import Foundation
import Alamofire
import PromiseKit
import ObjectMapper

open class PSBaseApiClient {
    private let session: Session
    private let credentials: PSApiJWTCredentials
    private let tokenRefresher: PSTokenRefresherProtocol?
    private let logger: PSLoggerProtocol?
    private var requestsQueue = [PSApiRequest]()
    
    public init(
        session: Session,
        credentials: PSApiJWTCredentials,
        tokenRefresher: PSTokenRefresherProtocol?,
        logger: PSLoggerProtocol? = nil
    ) {
        self.session = session
        self.tokenRefresher = tokenRefresher
        self.credentials = credentials
        self.logger = logger
    }
    
    public func doRequest<RC: URLRequestConvertible, E: Mappable>(requestRouter: RC) -> Promise<[E]> {
        let request = createRequest(requestRouter)
        makeRequest(apiRequest: request)
        
        return request
            .pendingPromise
            .promise
            .then(createPromiseWithArrayResult)
    }
    
    public func doRequest<RC: URLRequestConvertible, E: Mappable>(requestRouter: RC) -> Promise<E> {
        let request = createRequest(requestRouter)
        makeRequest(apiRequest: request)
        
        return request
            .pendingPromise
            .promise
            .then(createPromise)
    }
    
    public func doRequest<RC: URLRequestConvertible>(requestRouter: RC) -> Promise<Any> {
        let request = createRequest(requestRouter)
        makeRequest(apiRequest: request)
        
        return request
            .pendingPromise
            .promise
            .then(createPromise)
    }
    
    public func doRequest<RC: URLRequestConvertible>(requestRouter: RC) -> Promise<Void> {
        let request = createRequest(requestRouter)
        makeRequest(apiRequest: request)
        
        return request
            .pendingPromise
            .promise
            .then(createPromise)
    }
    
    private func makeRequest(apiRequest: PSApiRequest) {
        guard let urlRequest = apiRequest.requestEndPoint.urlRequest else { return }
        
        let lockQueue = DispatchQueue(label: String(describing: tokenRefresher), attributes: [])
        lockQueue.sync {
            if let tokenRefresher = tokenRefresher, tokenRefresher.isRefreshing() {
                requestsQueue.append(apiRequest)
            } else {
                self.logger?.log(
                    level: .DEBUG,
                    message: "--> \(urlRequest.url!.absoluteString)",
                    request: urlRequest
                )
                
                session
                    .request(apiRequest.requestEndPoint)
                    .responseJSON { (response) in
                        guard let urlResponse = response.response else {
                            apiRequest.pendingPromise.resolver.reject(PSApiError.unknown())
                            return
                        }
                        
                        let responseData = try? response.result.get()
                        let statusCode = urlResponse.statusCode
                        let logMessage = "<-- \(urlRequest.url!.absoluteString) \(statusCode)"
                        
                        if statusCode >= 200 && statusCode < 300 {
                            self.logger?.log(
                                level: .DEBUG,
                                message: logMessage,
                                response: urlResponse
                            )
                            apiRequest.pendingPromise.resolver.fulfill(responseData)
                        } else {
                            let error = self.mapError(body: responseData)
                            
                            self.logger?.log(
                                level: .ERROR,
                                message: logMessage,
                                response: urlResponse,
                                error: error
                            )
                            
                            if statusCode == 401 {
                                guard let tokenRefresher = self.tokenRefresher else {
                                    apiRequest.pendingPromise.resolver.reject(error)
                                    return
                                }
                                lockQueue.sync {
                                    if self.credentials.hasRecentlyRefreshed() {
                                        self.makeRequest(apiRequest: apiRequest)
                                        return
                                    }
                                    
                                    self.requestsQueue.append(apiRequest)
                                    
                                    if !tokenRefresher.isRefreshing() {
                                        tokenRefresher
                                            .refreshToken()
                                            .done { result in
                                                self.resumeQueue()
                                            }.catch { error in
                                                self.cancelQueue(error: error)
                                        }
                                    }
                                }
                            } else {
                                apiRequest.pendingPromise.resolver.reject(error)
                            }
                        }
                }
            }
        }
    }
    
    public func cancelAllOperations() {
        session.session.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
    }
    
    private func resumeQueue() {
        for request in requestsQueue {
            makeRequest(apiRequest: request)
        }
        requestsQueue.removeAll()
    }
    
    private func cancelQueue(error: Error) {
        for requests in requestsQueue {
            requests.pendingPromise.resolver.reject(error)
        }
        requestsQueue.removeAll()
    }
    
    private func createPromiseWithArrayResult<T: Mappable>(body: Any) -> Promise<[T]> {
        guard let objects = Mapper<T>().mapArray(JSONObject: body) else {
            return Promise(error: mapError(body: body))
        }
        return Promise.value(objects)
    }
    
    private func createPromise<T: Mappable>(body: Any) -> Promise<T> {
        guard let object = Mapper<T>().map(JSONObject: body) else {
            return Promise(error: mapError(body: body))
        }
        return Promise.value(object)
    }
    
    private func createPromise(body: Any) -> Promise<Void> {
        return Promise.value(())
    }
    
    private func createPromise(body: Any) -> Promise<Any> {
        return Promise.value(body)
    }
    
    private func mapError(body: Any?) -> PSApiError {
        if let apiError = Mapper<PSApiError>().map(JSONObject: body) {
            return apiError
        }
        
        return PSApiError.unknown()
    }
    
    private func createRequest<T: PSApiRequest, R: URLRequestConvertible>(_ endpoint: R) -> T {
        return T.init(pendingPromise: Promise<Any>.pending(), requestEndPoint: endpoint)
    }
}
