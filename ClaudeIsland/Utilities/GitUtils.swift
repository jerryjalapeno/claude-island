//
//  GitUtils.swift
//  ClaudeIsland
//
//  Utilities for extracting git repository information
//

import Foundation

/// Utilities for git repository information
enum GitUtils {
    /// Get the actual repository name from git remote URL
    /// Falls back to folder name if git commands fail
    /// - Parameter cwd: The working directory path
    /// - Returns: The repository name (e.g., "youtube" from "github.com/user/youtube")
    nonisolated static func getRepoName(cwd: String) -> String {
        // Try to get repo name from git remote URL
        if let repoName = getRepoNameFromRemote(cwd: cwd) {
            return repoName
        }

        // Fall back to folder name
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    /// Get repo name from git remote origin URL
    private nonisolated static func getRepoNameFromRemote(cwd: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", cwd, "remote", "get-url", "origin"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let urlString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !urlString.isEmpty else {
                return nil
            }

            return parseRepoNameFromURL(urlString)
        } catch {
            return nil
        }
    }

    /// Parse repository name from various git URL formats
    /// Supports: git@github.com:user/repo.git, https://github.com/user/repo.git, etc.
    private nonisolated static func parseRepoNameFromURL(_ urlString: String) -> String? {
        var path = urlString

        // Handle SSH format: git@github.com:user/repo.git
        if path.contains("@") && path.contains(":") && !path.contains("://") {
            if let colonIndex = path.lastIndex(of: ":") {
                path = String(path[path.index(after: colonIndex)...])
            }
        }

        // Handle HTTPS format: https://github.com/user/repo.git
        if let url = URL(string: path) {
            path = url.path
        }

        // Remove leading slash and .git suffix
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") {
            path = String(path.dropLast(4))
        }

        // Get last path component (repo name)
        // e.g., "user/repo" -> "repo"
        if let lastSlash = path.lastIndex(of: "/") {
            return String(path[path.index(after: lastSlash)...])
        }

        // Already just the repo name
        return path.isEmpty ? nil : path
    }
}
