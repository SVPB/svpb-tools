//
//  ServiceError.swift
//  TNG
//
//  Created by Stephen Beitzel on 3/16/26.
//

import Foundation

enum ServiceError: Error {
    case unexpectedResponseCode(String)
}
