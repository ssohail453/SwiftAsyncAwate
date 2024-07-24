
import UIKit
import SwiftUI
protocol HTTPClient {
    func sendRequest<T: Decodable>(endpoint: Endpoint, responseModel: T.Type) async -> Result<T, RequestError>
}

extension HTTPClient {
    func sendRequest<T: Decodable>(endpoint: Endpoint, responseModel: T.Type) async -> Result<T, RequestError> {
        if NetworkMonitor.shared.status == .disconnected {
            // Firebase analytics for error
            logError(message: "No Network available", code: "noNetwork")
            return .failure(.noNetwork)
        }
        
        var urlComponents = URLComponents()
        urlComponents.scheme = endpoint.scheme
        urlComponents.host = endpoint.host
        urlComponents.path = endpoint.path
        urlComponents.queryItems = addQueryItems(endpoint: endpoint)

        guard let url = urlComponents.url else {
            // Firebase analytics for error
            logError(message: "invalidURL", code: "invalidURL")
            return .failure(.invalidURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.allHTTPHeaderFields = endpoint.header
        request.setValue(ContentType.json.rawValue, forHTTPHeaderField: HTTPHeaderField.contentType.rawValue)
        request.setValue(ContentType.json.rawValue, forHTTPHeaderField: HTTPHeaderField.acceptType.rawValue)
        self.getFormattedBody(endpoint: endpoint, request: &request)
        LoggingManager.shared.print(request.curlString)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request, delegate: nil)
            LoggingManager.shared.print("RESPONSE: ")
            LoggingManager.shared.print(String(data: data, encoding: .utf8) ?? "")

            guard let response = response as? HTTPURLResponse else {
                return .failure(.noResponse)
            }
            LoggingManager.shared.print("STATUS CODE: \(response.statusCode)")
            switch response.statusCode {
            case 200...299:
                do {
                    let decodedResponse = try JSONDecoder().decode(responseModel, from: data)
                    return .success(decodedResponse)
                } catch let DecodingError.dataCorrupted(context) {
                    print(context)
                    logError(message: context.debugDescription, code: "decodeError")
                } catch let DecodingError.keyNotFound(key, context) {
                    print("Key '\(key)' not found:", context.debugDescription)
                    print("codingPath:", context.codingPath)
                    logError(message: context.debugDescription, code: "decodeError")
                } catch let DecodingError.valueNotFound(value, context) {
                    print("Value '\(value)' not found:", context.debugDescription)
                    print("codingPath:", context.codingPath)
                    logError(message: context.debugDescription, code: "decodeError")
                } catch let DecodingError.typeMismatch(type, context) {
                    print("Type '\(type)' mismatch:", context.debugDescription)
                    print("codingPath:", context.codingPath)
                    logError(message: context.debugDescription, code: "decodeError")
                } catch {
                    // Firebase analytics for error
                    logError(message: error.localizedDescription, code: "decodeError")
                    print("error: ", error)
                }
                return .failure(.decode)
            case 401:
                if endpoint.auhenticatorType == .appLevel {
                    let result = await ApplicationService().getApplicationToken()
                    switch result {
                    case .success(let response):
                        let updatedToken = response.data?.token ?? ""
                        _ = ValetHelper.shared.setStringValue(updatedToken, forKey: Constants.applicationToken)
                        return await self.sendRequest(endpoint: endpoint, responseModel: responseModel)
                    case .failure(let reason):
                        // Firebase analytics for error
                        logError(message: "Session expired", code: "unauthorized")
                        return .failure(reason)
                    }
                } else if endpoint.auhenticatorType == .userLevel {
                    if ValetHelper.shared.isLoggedIn {
                        let result = await ApplicationService().getApplicationToken()
                        switch result {
                        case .success(let response):
                            let updatedToken = response.data?.token ?? ""
                            _ = ValetHelper.shared.setStringValue(updatedToken, forKey: Constants.applicationToken)
                            let result = await ApplicationService().refreshUserToken()
                            switch result {
                            case .success(let response):
                                let updatedToken = response.data?.token ?? ""
                                _ = ValetHelper.shared.setStringValue(updatedToken, forKey: Constants.userToken)
                                return await self.sendRequest(endpoint: endpoint, responseModel: responseModel)
                            case .failure(let reason):
                                // Firebase analytics for error
                                logError(message: "Session expired", code: "unauthorized")
                                return .failure(reason)
                            }
                        case .failure(let reason):
                            // Firebase analytics for error
                            logError(message: "Session expired", code: "unauthorized")
                            return .failure(reason)
                        }
                    } else {
                        let result = await UserService().getUserToken(body: APIParameters.UserTokenRequestModel(individualID: ValetHelper.shared.individualId))
                        switch result {
                        case .success(let response):
                            let updatedToken = response.data?.token ?? ""
                            _ = ValetHelper.shared.setStringValue(updatedToken, forKey: Constants.userToken)
                            return await self.sendRequest(endpoint: endpoint, responseModel: responseModel)
                        case .failure(let reason):
                            // Firebase analytics for error
                            logError(message: "Session expired", code: "unauthorized")
                            return .failure(reason)
                        }
                    }
                } else if endpoint.auhenticatorType == .refreshToken {
                    DispatchQueue.main.async {
                        AppState.shared.tabSelection = .home
                        AppState.shared.homeViewPath = NavigationPath()
                        ShopUtility.webCacheclear()
                        ValetHelper.shared.performLogOut(retainAppToken: true)
                        AppState.shared.contactInfoEmailAddress = ""
                        AnalyticsManager.shared.logEvent(NSEventsName.kFIREventLogOut.rawValue)
                        AppState.shared.performLogoutAction = true
                    }
                    logError(message: "Session expired", code: "unauthorized")
                    return .failure(.unauthorized)
                } else {
                    // Firebase analytics for error
                    logError(message: "Session expired", code: "unauthorized")
                    return .failure(.unauthorized)
                }
            default:
                // try to decode the error response from server and make the error message
                guard let decodedResponse = try? JSONDecoder().decode(APIParameters.APIError.self, from: data) else {
                    guard let decodedResponse = try? JSONDecoder().decode(APIParameters.APICustomError.self, from: data) else {
                        // Firebase analytics for error
                        logError(message: "Unexpected status code", code: "unexpectedStatusCode")
                        return .failure(.unexpectedStatusCode)
                    }
                    // Firebase analytics for error
                    logError(message: decodedResponse.message ?? "", code: "unexpectedStatusCode")
                    return .failure(.customError(message: decodedResponse.message ?? ""))
                }
                // Firebase analytics for error
                logError(message: decodedResponse.errorMessage, code: decodedResponse.code)
                return .failure(.customCodeMessageError(message: [decodedResponse.code, decodedResponse.errorMessage]))
            }
        } catch {
            print(error.localizedDescription)
            // Firebase analytics for error
            logError(message: "Unknown error", code: "unknown")
            return .failure(.unknown)
        }
    }
    
    func getFormattedBody(endpoint: Endpoint, request: inout URLRequest) {
        if var body = endpoint.body, endpoint.isBodyAllow {
            body[Constants.brandId] = GlobalConfiguration.shared.brandID()
            let jsonData = try? JSONSerialization.data(withJSONObject: body)
            request.httpBody = jsonData
            LoggingManager.shared.print("BODY: \(body as Any)")
        }
    }
    
    func addQueryItems(endpoint: Endpoint) -> [URLQueryItem]? {
        var queryParams: [URLQueryItem]?
        if let params = endpoint.queryParams {
            if let productIDArray = params.values.first as? [String], productIDArray.isEmpty.negation {
                queryParams = []
                for currentID in productIDArray {
                    queryParams?.append(URLQueryItem(name: "categories[]", value: "\(currentID)"))
                }
            } else {
                queryParams = params.map { (key: String, value: Any) in
                    return URLQueryItem(name: key, value: "\(value)")
                }
            }
        }
        
        if endpoint.isBodyAllow == false, let body = endpoint.body {
            let params = body.map { (key: String, value: Any) in
                URLQueryItem(name: key, value: "\(value)")
            }
            
            if queryParams == nil {
                queryParams = params
            } else {
                queryParams?.append(contentsOf: params)
            }
        }
        
        queryParams?.append(URLQueryItem(name: Constants.brandId, value: GlobalConfiguration.shared.brandID()))
        return queryParams
    }
    
    func logError(message: String, code: String) {
        AnalyticsManager.shared.logEvent(NSEventsName.kFIREventError.rawValue, params: [
            "error_message": message,
            "error_type": code
        ])
    }
}


extension URLRequest {
    public var curlString: String {
        guard let url = url else { return "" }
        var baseCommand = #"curl "\#(url.absoluteString)""#

        if httpMethod == "HEAD" {
            baseCommand += " --head"
        }

        var command = [baseCommand]

        if let method = httpMethod {
            let isGetOrHead = (method == "GET" || method == "HEAD")
            if isGetOrHead == false {
                command.append("-X \(method)")
            }
        }

        if let headers = allHTTPHeaderFields {
            for (key, value) in headers {
                if key == "Cookie" {
                    continue
                }
                command.append("-H '\(key): \(value)'")
            }
        }

        if let data = httpBody, let body = String(data: data, encoding: .utf8) {
            command.append("-d '\(body)'")
        }

        return command.joined(separator: " \\\n\t")
    }
}
