import Foundation
import NetFS

/// Mounts network shares (SMB, AFP, NFS, WebDAV, FTP) with the system's own login UI and keychain.
enum ServerConnect {
    static let schemes = ["smb", "afp", "nfs", "cifs", "http", "https", "ftp"]

    /// Accepts "192.168.1.10/share" too (defaults to smb://).
    static func normalize(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "smb://" + trimmed
        guard let url = URL(string: withScheme) ?? URL(string: withScheme.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(), schemes.contains(scheme), url.host != nil else { return nil }
        return url
    }

    static func mount(_ url: URL, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let openOptions = NSMutableDictionary()
        openOptions["UIOption"] = "AllowUI" // kNAUIOptionKey = kNAUIOptionAllowUI: let NetFS ask for credentials
        let mountOptions = NSMutableDictionary()
        mountOptions["AllowSubMounts"] = true // kNetFSAllowSubMountsKey
        var requestID: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, mountOptions, &requestID, .main) { status, _, mountpoints in
            let result: Result<URL, Error>
            if status == 0, let path = (mountpoints as? [String])?.first {
                result = .success(URL(fileURLWithPath: path))
            } else {
                result = .failure(error(for: status, url: url))
            }
            MainActor.assumeIsolated { completion(result) }
        }
        if status != 0 {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(.failure(error(for: status, url: url))) } }
        }
    }

    private static func error(for status: Int32, url: URL) -> Error {
        let reason: String
        switch status {
        case ECANCELED, -128: reason = L("已取消连接。")
        case ENOENT: reason = L("找不到这个共享。")
        case EAUTH, EACCES, EPERM: reason = L("用户名或密码不正确。")
        case ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN: reason = L("无法访问服务器，请检查地址和网络。")
        default: reason = L("错误代码 \(status)。")
        }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: L("无法连接到“\(url.host ?? url.absoluteString)”：\(reason)")])
    }
}
