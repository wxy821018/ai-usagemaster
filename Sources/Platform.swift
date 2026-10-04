// 平台差异：数据目录、绝对路径判断、文件信息与身份、整体替换文件、几个 POSIX 小工具
//
// macOS 的实现就是原来散在各文件里的写法（stat、realpath、rename），行为不变；
// Windows 上对应的系统调用不同，且有几处不能照搬：stat 的 st_ino 恒为 0（按 inode 去重会把所有文件当成同一个），
// CRT 的 rename 遇到目标已存在会失败，open 默认文本模式（写 \n 变 \r\n）。

#if os(Windows)
import WinSDK
#endif
import Foundation

// MARK: - 目录

#if os(Windows)
/// 其它应用（Cursor、Orca、OpenCode）放数据的根目录：%APPDATA%
let appSupportRoot = ProcessInfo.processInfo.environment["APPDATA"].flatMap { $0.isEmpty ? nil : $0 }
    ?? NSHomeDirectory() + "/AppData/Roaming"
#else
/// 其它应用（Cursor、Orca、OpenCode）放数据的根目录
let appSupportRoot = NSHomeDirectory() + "/Library/Application Support"
#endif

/// UsageMaster 自己的数据目录：缓存、历史、费用报告、状态行快照
let appDataDir = appSupportRoot + "/UsageMaster"

/// 绝对路径：/ 开头；Windows 上还有 C:\ 或 C:/（盘符）、\\server\share（UNC）、\ 开头（当前盘的根）。
/// git 在 Windows 上写进 worktree 的 .git 文件里的是 C:/repo/.git/worktrees/x 这种形式
func isAbsolutePath(_ p: String) -> Bool {
    if p.hasPrefix("/") { return true }
    #if os(Windows)
    if p.hasPrefix("\\") { return true }
    let c = Array(p.utf8.prefix(3))
    if c.count == 3, (c[0] >= 65 && c[0] <= 90) || (c[0] >= 97 && c[0] <= 122), c[1] == 58, c[2] == 47 || c[2] == 92 { return true }
    #endif
    return false
}

// MARK: - 文件信息

/// 一个路径的类型、大小、修改时间，以及「是不是同一个文件」的身份（软链/硬链指向同一个文件时身份相同）
struct FileInfo {
    var isDirectory: Bool
    var isRegularFile: Bool
    var size: Int
    var mtimeMs: Int
    var identity: String
}

enum FileInfoResult { case ok(FileInfo), missing, denied }

#if os(Windows)
/// 身份 = 卷序列号 + 文件索引（NTFS 上相当于 inode）；修改时间精确到毫秒。
/// 打开时跟随符号链接和目录联接，和 stat 一样看的是目标
func fileInfo(_ path: String) -> FileInfoResult {
    let h = path.withCString(encodedAs: UTF16.self) {
        CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                    DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
    }
    guard let h, h != INVALID_HANDLE_VALUE else {
        return GetLastError() == DWORD(ERROR_ACCESS_DENIED) ? .denied : .missing
    }
    defer { CloseHandle(h) }
    var info = BY_HANDLE_FILE_INFORMATION()
    guard GetFileInformationByHandle(h, &info) else { return .missing }
    let isDir = info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0
    let size = Int(info.nFileSizeHigh) << 32 | Int(info.nFileSizeLow)
    // FILETIME：1601-01-01 起的 100 纳秒数
    let ft = Int64(info.ftLastWriteTime.dwHighDateTime) << 32 | Int64(info.ftLastWriteTime.dwLowDateTime)
    let ms = Int((ft - 116_444_736_000_000_000) / 10_000)
    let id = "\(info.dwVolumeSerialNumber):\(info.nFileIndexHigh):\(info.nFileIndexLow)"
    return .ok(FileInfo(isDirectory: isDir, isRegularFile: !isDir, size: isDir ? 0 : size, mtimeMs: ms, identity: id))
}
#else
/// 身份 = (设备, inode)
func fileInfo(_ path: String) -> FileInfoResult {
    var st = stat()
    guard stat(path, &st) == 0 else { return (errno == EPERM || errno == EACCES) ? .denied : .missing }
    let kind = st.st_mode & S_IFMT
    let ms = Int(st.st_mtimespec.tv_sec) * 1000 + Int(st.st_mtimespec.tv_nsec) / 1_000_000
    return .ok(FileInfo(isDirectory: kind == S_IFDIR, isRegularFile: kind == S_IFREG, size: Int(st.st_size), mtimeMs: ms,
                        identity: "\(st.st_dev):\(st.st_ino)"))
}
#endif

/// 去掉软链、. 和 ..，得到规范路径；路径不存在时原样返回。
/// Windows 上结果统一成 C:\a\b 的写法（git 写的 C:/a/b 和日志里的 C:\a\b 会归成同一个）
func realPath(_ p: String) -> String {
    #if os(Windows)
    let h = p.withCString(encodedAs: UTF16.self) {
        CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil,
                    DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
    }
    guard let h, h != INVALID_HANDLE_VALUE else { return p }
    defer { CloseHandle(h) }
    var buf = [WCHAR](repeating: 0, count: 32_768)
    let n = GetFinalPathNameByHandleW(h, &buf, DWORD(buf.count), DWORD(FILE_NAME_NORMALIZED))
    guard n > 0, Int(n) < buf.count else { return p }
    var s = String(decoding: buf[..<Int(n)], as: UTF16.self)
    if s.hasPrefix(#"\\?\UNC\"#) { s = #"\\"# + s.dropFirst(8) }
    else if s.hasPrefix(#"\\?\"#) { s = String(s.dropFirst(4)) }
    return s
    #else
    guard let r = realpath(p, nil) else { return p }
    defer { free(r) }
    return String(cString: r)
    #endif
}

// MARK: - 写文件

/// 用 tmp 整体替换 path（同一卷上是原子的：读的人只会看到旧的或新的完整内容）。成功返回 true；失败时 tmp 留给调用方清理。
/// POSIX rename 直接覆盖；Windows 的 CRT rename 遇到目标已存在会失败，改用 MoveFileEx，
/// 且目标可能正被别的进程短暂打开（比如 Claude Code 在读凭据），失败时重试几次
func replaceFile(_ tmp: String, _ path: String) -> Bool {
    #if os(Windows)
    for attempt in 0..<10 {
        let ok = tmp.withCString(encodedAs: UTF16.self) { from in
            path.withCString(encodedAs: UTF16.self) { to in
                MoveFileExW(from, to, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
            }
        }
        if ok { return true }
        if attempt < 9 { Thread.sleep(forTimeInterval: 0.1) }
    }
    return false
    #else
    return rename(tmp, path) == 0
    #endif
}

/// open() 要加的二进制标志：Windows 默认文本模式会把 \n 写成 \r\n
#if os(Windows)
let openBinaryFlag: Int32 = _O_BINARY
#else
let openBinaryFlag: Int32 = 0
#endif

/// 往文件描述符写，返回写了多少字节（出错为负）
func writeFD(_ fd: Int32, _ buf: UnsafeRawPointer, _ n: Int) -> Int {
    #if os(Windows)
    return Int(_write(fd, buf, UInt32(min(n, Int(Int32.max)))))
    #else
    return write(fd, buf, n)
    #endif
}

// MARK: - Windows 上缺的几个函数

#if os(Windows)
/// Windows 上没有 Objective-C 的自动释放池，直接执行
func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }

/// memmem：Windows CRT 没有
func memmem(_ hay: UnsafeRawPointer, _ hn: Int, _ needle: UnsafeRawPointer, _ nn: Int) -> UnsafeMutableRawPointer? {
    if nn == 0 { return UnsafeMutableRawPointer(mutating: hay) }
    guard hn >= nn else { return nil }
    let h = hay.assumingMemoryBound(to: UInt8.self), n = needle.assumingMemoryBound(to: UInt8.self)
    let first = n[0]
    var i = 0
    while i <= hn - nn {
        if h[i] == first && memcmp(h + i, n, nn) == 0 { return UnsafeMutableRawPointer(mutating: h + i) }
        i += 1
    }
    return nil
}
#endif
