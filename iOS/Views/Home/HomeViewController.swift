import UIKit
import ZIPFoundation

class HomeViewController: UIViewController, UISearchResultsUpdating, UIDocumentPickerDelegate, FileHandlingDelegate, UITableViewDelegate, UITableViewDataSource, UITableViewDragDelegate, UITableViewDropDelegate {
    
    // MARK: - Properties
    var fileList: [File] = []
    private var filteredFileList: [File] = []
    private let fileManager = FileManager.default
    private let searchController = UISearchController(searchResultsController: nil)
    private var sortOrder: SortOrder = .name
    private let fileHandlers = HomeViewFileHandlers()
    private let utilities = HomeViewUtilities()
    private let tableHandlers = HomeViewTableHandlers(utilities: HomeViewUtilities()) // Initialize with utilities
    
    /// The base directory for storing files
    /// Uses the app's documents directory with a "files" subdirectory
    var documentsDirectory: URL {
        get {
            // Get the documents directory safely
            guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                // This is a serious error - log it and return a fallback directory
                Debug.shared.log(message: "Failed to get documents directory, using temporary directory as fallback", type: .error)
                return FileManager.default.temporaryDirectory.appendingPathComponent("files")
            }
            
            // Create the files subdirectory
            let directory = documentsURL.appendingPathComponent("files")
            createFilesDirectoryIfNeeded(at: directory)
            return directory
        }
    }
    
    enum SortOrder: String {
        case name, date, size
    }
    
    var activityIndicator: UIActivityIndicatorView {
        return HomeViewUI.activityIndicator
    }
    
    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupActivityIndicator()
        loadFiles()
        configureTableView()
    }
    
    deinit {
        // No observation to invalidate
    }
    
    // MARK: - UI Setup
    private func setupUI() {
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.9)
        view.layer.applyFuturisticShadow()
        
        let navItem = UINavigationItem(title: "File Nexus")
        let menuButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle.fill"), style: .plain, target: self, action: #selector(showMenu))
        let uploadButton = UIBarButtonItem(customView: HomeViewUI.uploadButton)
        let addButton = UIBarButtonItem(image: UIImage(systemName: "folder.badge.plus"), style: .plain, target: self, action: #selector(addDirectory))
        
        HomeViewUI.uploadButton.addTarget(self, action: #selector(importFile), for: .touchUpInside)
        HomeViewUI.uploadButton.addGradientBackground()
        navItem.rightBarButtonItems = [menuButton, uploadButton, addButton]
        HomeViewUI.navigationBar.setItems([navItem], animated: false)
        view.addSubview(HomeViewUI.navigationBar)
        
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search Files"
        searchController.searchBar.tintColor = .systemCyan
        navigationItem.searchController = searchController
        definesPresentationContext = true
        
        view.addSubview(HomeViewUI.fileListTableView)
        NSLayoutConstraint.activate([
            HomeViewUI.navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            HomeViewUI.navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            HomeViewUI.navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            HomeViewUI.fileListTableView.topAnchor.constraint(equalTo: HomeViewUI.navigationBar.bottomAnchor, constant: 10),
            HomeViewUI.fileListTableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            HomeViewUI.fileListTableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            HomeViewUI.fileListTableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10)
        ])
        
        applyFuturisticTransition()
    }
    
    private func setupActivityIndicator() {
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    
    private func configureTableView() {
        HomeViewUI.fileListTableView.delegate = self
        HomeViewUI.fileListTableView.dataSource = self
        HomeViewUI.fileListTableView.dragDelegate = self
        HomeViewUI.fileListTableView.dropDelegate = self
        HomeViewUI.fileListTableView.register(FileTableViewCell.self, forCellReuseIdentifier: "FileCell")
        HomeViewUI.fileListTableView.backgroundColor = .clear
        HomeViewUI.fileListTableView.layer.cornerRadius = 15
        HomeViewUI.fileListTableView.layer.applyFuturisticShadow()
    }
    
    /// Creates the files directory if it doesn't exist
    /// - Parameter directory: The directory URL to create
    /// - Returns: True if the directory exists or was created successfully, false otherwise
    @discardableResult
    private func createFilesDirectoryIfNeeded(at directory: URL) -> Bool {
        // Check if directory already exists
        if fileManager.fileExists(atPath: directory.path) {
            return true
        }
        
        // Directory doesn't exist, try to create it
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            Debug.shared.log(message: "Created directory: \(directory.path)", type: .info)
            return true
        } catch {
            // Log the error and show to user
            Debug.shared.log(message: "Failed to create directory: \(error.localizedDescription)", type: .error)
            utilities.handleError(in: self, error: error, withTitle: "Directory Creation Error")
            return false
        }
    }
    
    private func saveState() {
        UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder")
    }
    
    // MARK: - File Operations
    
    /// Loads files from the documents directory and updates the UI
    func loadFiles() {
        // Start loading indicator
        activityIndicator.startAnimating()
        
        // Determine which directory to load
        let directoryToLoad = currentDirectory ?? documentsDirectory
        
        // If loading root directory, ensure it exists
        if directoryToLoad == documentsDirectory {
            if !createFilesDirectoryIfNeeded(at: documentsDirectory) {
                // If we can't create the directory, stop loading
                activityIndicator.stopAnimating()
                return
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Capture the start time for performance measurement
            let startTime = Date()
            
            do {
                // Load directory contents with necessary file attributes
                let fileURLs = try self.fileManager.contentsOfDirectory(
                    at: directoryToLoad,
                    includingPropertiesForKeys: [
                        .creationDateKey,
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isDirectoryKey
                    ],
                    options: .skipsHiddenFiles
                )
                
                // Create File objects with cached attributes for better performance
                // This avoids accessing the filesystem repeatedly when displaying files
                var fileObjects: [File] = []
                for fileURL in fileURLs {
                    let file = File(url: fileURL)
                    fileObjects.append(file)
                }
                
                // Calculate loading time for performance monitoring
                let loadTime = Date().timeIntervalSince(startTime)
                Debug.shared.log(message: "Loaded \(fileObjects.count) files in \(String(format: "%.3f", loadTime))s", type: .info)
                
                // Update UI on main thread
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    self.fileList = fileObjects
                    self.sortFiles()
                    HomeViewUI.fileListTableView.reloadData()
                    self.activityIndicator.stopAnimating()
                    
                    // Update navigation UI based on current directory
                    if directoryToLoad != self.documentsDirectory {
                        self.addNavigationBackButtonIfNeeded()
                        self.title = directoryToLoad.lastPathComponent
                    } else {
                        self.title = "File Nexus"
                    }
                    
                    // If no files, show a helpful message
                    if fileObjects.isEmpty {
                        self.showEmptyStateMessage()
                    } else {
                        self.hideEmptyStateMessage()
                    }
                }
            } catch {
                Debug.shared.log(message: "Failed to load files: \(error.localizedDescription)", type: .error)
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    self.activityIndicator.stopAnimating()
                    self.utilities.handleError(in: self, error: error, withTitle: "File Load Error")
                    
                    // Show empty state with error
                    self.showEmptyStateMessage(withError: error)
                }
            }
        }
    }
    
    /// Shows a message when the file list is empty
    /// - Parameter error: Optional error to show
    private func showEmptyStateMessage(withError error: Error? = nil) {
        // Check if we already have an empty state label
        if let existingLabel = view.viewWithTag(1001) as? UILabel {
            existingLabel.isHidden = false
            
            if let error = error {
                existingLabel.text = "Could not load files.\n\(error.localizedDescription)\n\nTap the upload button to add files."
            } else {
                existingLabel.text = "No files found.\n\nTap the upload button to add files."
            }
            return
        }
        
        // Create a new empty state label
        let emptyLabel = UILabel()
        emptyLabel.tag = 1001
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .systemFont(ofSize: 16)
        
        if let error = error {
            emptyLabel.text = "Could not load files.\n\(error.localizedDescription)\n\nTap the upload button to add files."
        } else {
            emptyLabel.text = "No files found.\n\nTap the upload button to add files."
        }
        
        view.addSubview(emptyLabel)
        
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: HomeViewUI.fileListTableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: HomeViewUI.fileListTableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: HomeViewUI.fileListTableView.leadingAnchor, constant: 40),
            emptyLabel.trailingAnchor.constraint(equalTo: HomeViewUI.fileListTableView.trailingAnchor, constant: -40)
        ])
    }
    
    /// Hides the empty state message
    private func hideEmptyStateMessage() {
        if let emptyLabel = view.viewWithTag(1001) {
            emptyLabel.isHidden = true
        }
    }
    
    /// Initiates the file import process
    @objc private func importFile() {
        // Show action sheet to give upload options
        let actionSheet = UIAlertController(
            title: "Upload File",
            message: "Choose how you'd like to upload",
            preferredStyle: .actionSheet
        )
        
        // Add actions for different upload methods
        let documentAction = UIAlertAction(title: "Browse Files", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.fileHandlers.uploadFile(viewController: self)
        }
        
        let createFileAction = UIAlertAction(title: "Create New Text File", style: .default) { [weak self] _ in
            guard let self = self else { return }
            self.createNewTextFile()
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        // Add icons to actions
        documentAction.setValue(UIImage(systemName: "doc"), forKey: "image")
        createFileAction.setValue(UIImage(systemName: "doc.badge.plus"), forKey: "image")
        
        // Add actions to action sheet
        actionSheet.addAction(documentAction)
        actionSheet.addAction(createFileAction)
        actionSheet.addAction(cancelAction)
        
        // Configure popover for iPad
        if let popover = actionSheet.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?[1]
        }
        
        present(actionSheet, animated: true)
    }
    
    /// Creates a new text file
    private func createNewTextFile() {
        let alertController = UIAlertController(
            title: "Create New Text File",
            message: "Enter a name for the new file",
            preferredStyle: .alert
        )
        
        alertController.addTextField { textField in
            textField.placeholder = "Filename.txt"
            textField.autocapitalizationType = .none
        }
        
        let createAction = UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            guard let self = self,
                  let textField = alertController.textFields?.first,
                  var fileName = textField.text?.trimmingCharacters(in: .whitespaces),
                  !fileName.isEmpty else { return }
            
            // Add .txt extension if not provided
            if !fileName.lowercased().hasSuffix(".txt") {
                fileName += ".txt"
            }
            
            // Create in current directory or root
            let targetDirectory = self.currentDirectory ?? self.documentsDirectory
            let newFileURL = targetDirectory.appendingPathComponent(fileName)
            
            // Generate unique filename if needed
            let uniqueFileName = self.getUniqueFileName(for: fileName)
            let uniqueFileURL = targetDirectory.appendingPathComponent(uniqueFileName)
            
            do {
                // Create empty text file
                try "".write(to: uniqueFileURL, atomically: true, encoding: .utf8)
                self.loadFiles()
                HapticFeedbackGenerator.generateNotificationFeedback(type: .success)
                
                // Open the file for editing
                let editor = TextEditorViewController(fileURL: uniqueFileURL)
                self.navigationController?.pushViewController(editor, animated: true)
            } catch {
                self.utilities.handleError(in: self, error: error, withTitle: "File Creation Error")
            }
        }
        
        alertController.addAction(createAction)
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alertController, animated: true)
    }
    
    /// Handles a file that has been imported from outside the app
    /// - Parameter url: The URL of the imported file
    func handleImportedFile(url: URL) {
        // Show loading indicator
        activityIndicator.startAnimating()
        
        // Determine target directory (current directory or root)
        let targetDirectory = currentDirectory ?? documentsDirectory
        
        // Generate a unique name if a file with the same name exists
        let fileName = getUniqueFileName(for: url.lastPathComponent)
        let destinationURL = targetDirectory.appendingPathComponent(fileName)
        
        Debug.shared.log(message: "Importing file from \(url.path) to \(destinationURL.path)", type: .info)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Flag to track if we need to access security-scoped resource
            let needsSecurityScopedAccess = url.startAccessingSecurityScopedResource()
            
            // Use a local function to stop accessing security-scoped resource
            // This ensures it's called in all code paths
            func stopAccessingIfNeeded() {
                if needsSecurityScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                    Debug.shared.log(message: "Stopped accessing security scoped resource", type: .debug)
                }
            }
            
            do {
                // Handle ZIP files specially - extract their contents
                if url.pathExtension.lowercased() == "zip" {
                    Debug.shared.log(message: "Extracting ZIP file", type: .info)
                    
                    // Extract ZIP directly in the current task
                    try self.fileManager.unzipItem(at: url, to: targetDirectory)
                    
                    // Stop accessing security-scoped resource after extraction
                    stopAccessingIfNeeded()
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        self.activityIndicator.stopAnimating()
                        self.loadFiles()
                        HapticFeedbackGenerator.generateNotificationFeedback(type: .success)
                        
                        // Show success message
                        let alert = UIAlertController(
                            title: "ZIP Extracted",
                            message: "The ZIP file has been extracted to \(targetDirectory == self.documentsDirectory ? "your files" : "the current folder").",
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.present(alert, animated: true, completion: nil)
                    }
                } else {
                    // For non-ZIP files, copy the file to destination
                    Debug.shared.log(message: "Copying file", type: .info)
                    
                    // Check if destination already exists and delete if necessary
                    if self.fileManager.fileExists(atPath: destinationURL.path) {
                        try self.fileManager.removeItem(at: destinationURL)
                    }
                    
                    // Copy the file
                    try self.fileManager.copyItem(at: url, to: destinationURL)
                    
                    // Stop accessing security-scoped resource after copy
                    stopAccessingIfNeeded()
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        self.activityIndicator.stopAnimating()
                        self.loadFiles()
                        HapticFeedbackGenerator.generateNotificationFeedback(type: .success)
                        
                        // Show success message
                        let alert = UIAlertController(
                            title: "File Imported",
                            message: "\(fileName) has been imported successfully.",
                            preferredStyle: .alert
                        )
                        alert.addAction(UIAlertAction(title: "OK", style: .default))
                        self.present(alert, animated: true, completion: nil)
                    }
                }
            } catch {
                // Stop accessing security-scoped resource on error
                stopAccessingIfNeeded()
                
                Debug.shared.log(message: "Import error: \(error.localizedDescription)", type: .error)
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    self.activityIndicator.stopAnimating()
                    self.utilities.handleError(
                        in: self,
                        error: error,
                        withTitle: "File Import Error"
                    )
                }
            }
        }
    }
    
    /// Generates a unique filename if the original already exists
    /// - Parameter filename: The original filename
    /// - Returns: A unique filename
    private func getUniqueFileName(for filename: String) -> String {
        // Determine target directory (current directory or root)
        let targetDirectory = currentDirectory ?? documentsDirectory
        
        let fileURL = targetDirectory.appendingPathComponent(filename)
        
        // If the file doesn't exist, return the original name
        if !fileManager.fileExists(atPath: fileURL.path) {
            return filename
        }
        
        // Split the name and extension
        let fileExtension = fileURL.pathExtension
        let baseName = filename.replacingOccurrences(
            of: ".\(fileExtension)$",
            with: "",
            options: .regularExpression
        )
        
        // Try adding numbers until we find a unique name
        var counter = 1
        var newName: String
        var newURL: URL
        
        repeat {
            if fileExtension.isEmpty {
                newName = "\(baseName) (\(counter))"
            } else {
                newName = "\(baseName) (\(counter)).\(fileExtension)"
            }
            newURL = targetDirectory.appendingPathComponent(newName)
            counter += 1
        } while fileManager.fileExists(atPath: newURL.path)
        
        return newName
    }
    
    /// Deletes a file at the specified index
    /// - Parameter index: The index of the file to delete
    func deleteFile(at index: Int) {
        // Get the file based on whether we're in search mode or not
        let file = searchController.isActive ? filteredFileList[index] : fileList[index]
        let fileURL = file.url
        
        // Confirm deletion to prevent accidental data loss
        let fileType = file.isDirectory ? "folder" : "file"
        let message = "Are you sure you want to delete this \(fileType)?\n\nName: \(file.name)\n\(file.formattedSize())"
        
        let alert = UIAlertController(
            title: "Confirm Deletion",
            message: message,
            preferredStyle: .alert
        )
        
        let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.performFileDeletion(file: file, at: index)
        }
        
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel)
        
        alert.addAction(deleteAction)
        alert.addAction(cancelAction)
        present(alert, animated: true, completion: nil)
    }
    
    /// Performs the actual deletion operation after confirmation
    /// - Parameters:
    ///   - file: The file to delete
    ///   - index: The index of the file
    private func performFileDeletion(file: File, at index: Int) {
        activityIndicator.startAnimating()
        
        Debug.shared.log(message: "Deleting file: \(file.url.path)", type: .info)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                // Check if the file still exists before attempting deletion
                if !self.fileManager.fileExists(atPath: file.url.path) {
                    Debug.shared.log(message: "File does not exist during deletion: \(file.url.path)", type: .warning)
                    
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        // File doesn't exist, update UI anyway
                        self.updateUIAfterDeletion(file: file, index: index)
                        self.activityIndicator.stopAnimating()
                        
                        // Show warning
                        self.utilities.handleError(
                            in: self,
                            error: FileAppError.fileNotFound(file.name),
                            withTitle: "File Already Deleted"
                        )
                    }
                    return
                }
                
                // Perform the deletion
                try self.fileManager.removeItem(at: file.url)
                
                Debug.shared.log(message: "Successfully deleted: \(file.url.path)", type: .info)
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    // Update the UI
                    self.updateUIAfterDeletion(file: file, index: index)
                    self.activityIndicator.stopAnimating()
                    
                    // Provide success feedback
                    HapticFeedbackGenerator.generateNotificationFeedback(type: .success)
                }
            } catch {
                Debug.shared.log(message: "Error deleting file: \(error.localizedDescription)", type: .error)
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    self.activityIndicator.stopAnimating()
                    self.utilities.handleError(in: self, error: error, withTitle: "File Delete Error")
                }
            }
        }
    }
    
    /// Updates the UI after a file has been deleted
    /// - Parameters:
    ///   - file: The file that was deleted
    ///   - index: The index of the file
    private func updateUIAfterDeletion(file: File, index: Int) {
        // Update the appropriate file list
        if searchController.isActive {
            if let foundIndex = filteredFileList.firstIndex(of: file) {
                filteredFileList.remove(at: foundIndex)
                HomeViewUI.fileListTableView.deleteRows(at: [IndexPath(row: foundIndex, section: 0)], with: .fade)
            }
        } else {
            if index < fileList.count && fileList[index] == file {
                fileList.remove(at: index)
                HomeViewUI.fileListTableView.deleteRows(at: [IndexPath(row: index, section: 0)], with: .fade)
            } else if let foundIndex = fileList.firstIndex(of: file) {
                // Failsafe if index doesn't match
                fileList.remove(at: foundIndex)
                HomeViewUI.fileListTableView.deleteRows(at: [IndexPath(row: foundIndex, section: 0)], with: .fade)
            }
        }
        
        // Show empty state if necessary
        if fileList.isEmpty {
            showEmptyStateMessage()
        }
    }
    
    private func sortFiles() {
        switch sortOrder {
        case .name:
            fileList.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .date:
            fileList.sort { $0.date > $1.date }
        case .size:
            fileList.sort { $0.size > $1.size }
        }
    }
    
    // MARK: - UI Actions
    @objc private func showMenu() {
        let alertController = UIAlertController(title: "Sort By", message: nil, preferredStyle: .actionSheet)
        
        let sortByNameAction = UIAlertAction(title: "Name", style: .default) { _ in
            self.sortOrder = .name
            self.sortFiles()
            HomeViewUI.fileListTableView.reloadData()
        }
        let sortByDateAction = UIAlertAction(title: "Date", style: .default) { _ in
            self.sortOrder = .date
            self.sortFiles()
            HomeViewUI.fileListTableView.reloadData()
        }
        let sortBySizeAction = UIAlertAction(title: "Size", style: .default) { _ in
            self.sortOrder = .size
            self.sortFiles()
            HomeViewUI.fileListTableView.reloadData()
        }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(sortByNameAction)
        alertController.addAction(sortByDateAction)
        alertController.addAction(sortBySizeAction)
        alertController.addAction(cancelAction)
        
        if let popover = alertController.popoverPresentationController {
            popover.barButtonItem = navigationItem.rightBarButtonItems?.first
        }
        present(alertController, animated: true, completion: nil)
    }
    
    func updateSearchResults(for searchController: UISearchController) {
        guard let searchText = searchController.searchBar.text?.lowercased() else { return }
        filteredFileList = fileList.filter { $0.name.lowercased().contains(searchText) }
        HomeViewUI.fileListTableView.reloadData()
    }
    
    @objc private func addDirectory() {
        let alertController = UIAlertController(title: "Add Directory", message: "Enter the name of the new directory", preferredStyle: .alert)
        alertController.addTextField { textField in
            textField.placeholder = "Directory Name"
            textField.autocapitalizationType = .none
        }
        
        let createAction = UIAlertAction(title: "Create", style: .default) { _ in
            guard let textField = alertController.textFields?.first,
                  let directoryName = textField.text?.trimmingCharacters(in: .whitespaces),
                  !directoryName.isEmpty else { return }
            
            // Create in current directory or root
            let targetDirectory = self.currentDirectory ?? self.documentsDirectory
            let newDirectoryURL = targetDirectory.appendingPathComponent(directoryName)
            
            // Check if directory already exists
            if self.fileManager.fileExists(atPath: newDirectoryURL.path) {
                self.utilities.handleError(
                    in: self,
                    error: FileAppError.fileAlreadyExists(directoryName),
                    withTitle: "Directory Creation Error"
                )
                return
            }
            
            do {
                try self.fileManager.createDirectory(at: newDirectoryURL, withIntermediateDirectories: false, attributes: nil)
                self.loadFiles()
                HapticFeedbackGenerator.generateNotificationFeedback(type: .success)
                
                // Show success message
                let alert = UIAlertController(
                    title: "Directory Created",
                    message: "Directory '\(directoryName)' has been created successfully.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true, completion: nil)
            } catch {
                self.utilities.handleError(in: self, error: error, withTitle: "Directory Creation Error")
            }
        }
        alertController.addAction(createAction)
        alertController.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        present(alertController, animated: true, completion: nil)
    }
    
    private func showFileOptions(for file: File) {
        let alertController = UIAlertController(title: "File Options", message: file.name, preferredStyle: .actionSheet)
        
        let openAction = UIAlertAction(title: "Open", style: .default) { _ in
            self.openFile(file)
        }
        let deleteAction = UIAlertAction(title: "Delete", style: .destructive) { _ in
            if let index = self.fileList.firstIndex(of: file) {
                self.deleteFile(at: index)
            }
        }
        let shareAction = UIAlertAction(title: "Share", style: .default) { _ in
            self.fileHandlers.shareFile(viewController: self, fileURL: file.url)
        }
        let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
        alertController.addAction(openAction)
        alertController.addAction(deleteAction)
        alertController.addAction(shareAction)
        alertController.addAction(cancelAction)
        
        if let popover = alertController.popoverPresentationController {
            if let cell = HomeViewUI.fileListTableView.cellForRow(at: IndexPath(row: self.fileList.firstIndex(of: file) ?? 0, section: 0)) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            }
        }
        present(alertController, animated: true, completion: nil)
    }
    
    private func openFile(_ file: File) {
        // If this is a directory, navigate into it
        if file.isDirectory {
            navigateToFolder(file.url)
            return
        }
        
        let fileExtension = file.url.pathExtension.lowercased()
        switch fileExtension {
        case "txt", "md":
            let editor = TextEditorViewController(fileURL: file.url)
            navigationController?.pushViewController(editor, animated: true)
        case "plist":
            let editor = PlistEditorViewController(fileURL: file.url)
            navigationController?.pushViewController(editor, animated: true)
        case "ipa":
            let editor = IPAEditorViewController(fileURL: file.url)
            navigationController?.pushViewController(editor, animated: true)
        default:
            let editor = HexEditorViewController(fileURL: file.url)
            navigationController?.pushViewController(editor, animated: true)
        }
    }
    
    /// Current directory stack for navigation
    private var directoryStack: [URL] = []
    
    /// Current directory being displayed
    private var currentDirectory: URL?
    
    /// Navigate into a folder
    /// - Parameter folderURL: URL of the folder to navigate into
    private func navigateToFolder(_ folderURL: URL) {
        activityIndicator.startAnimating()
        
        // Save current directory to stack if it exists
        if let currentDir = currentDirectory {
            directoryStack.append(currentDir)
        } else {
            // First navigation, save the documents directory
            directoryStack.append(documentsDirectory)
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                // Get contents of the selected directory
                let directoryContents = try self.fileManager.contentsOfDirectory(
                    at: folderURL,
                    includingPropertiesForKeys: [
                        .creationDateKey,
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isDirectoryKey
                    ],
                    options: .skipsHiddenFiles
                )
                
                // Create File objects
                var folderFiles: [File] = []
                for fileURL in directoryContents {
                    let file = File(url: fileURL)
                    folderFiles.append(file)
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    self.fileList = folderFiles
                    self.currentDirectory = folderURL
                    self.sortFiles()
                    self.tableView.reloadData()
                    self.activityIndicator.stopAnimating()
                    
                    // Update navigation title to show current folder
                    self.title = folderURL.lastPathComponent
                    
                    // Add back button if not already present
                    self.addNavigationBackButtonIfNeeded()
                    
                    // If no files, show a helpful message
                    if folderFiles.isEmpty {
                        self.showEmptyStateMessage()
                    } else {
                        self.hideEmptyStateMessage()
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    self.activityIndicator.stopAnimating()
                    Debug.shared.log(message: "Directory navigation error: \(error.localizedDescription)", type: .error)
                    self.utilities.handleError(in: self, error: error, withTitle: "Folder Navigation Error")
                }
            }
        }
    }
    
    /// Add a back button to the navigation bar if needed
    private func addNavigationBackButtonIfNeeded() {
        // If we're in a subdirectory, we need a back button
        if !directoryStack.isEmpty {
            // Check if we already have a back button
            let backButton = UIBarButtonItem(
                image: UIImage(systemName: "chevron.backward"),
                style: .plain,
                target: self,
                action: #selector(navigateBack)
            )
            
            // Get the current right bar button items
            var rightBarItems = navigationItem.rightBarButtonItems ?? []
            
            // Make sure we don't already have a back button
            if !rightBarItems.contains(where: { 
                ($0.action == #selector(navigateBack)) 
            }) {
                rightBarItems.append(backButton)
                navigationItem.rightBarButtonItems = rightBarItems
            }
        }
    }
    
    /// Navigate back to the previous directory
    @objc private func navigateBack() {
        guard !directoryStack.isEmpty else { return }
        
        activityIndicator.startAnimating()
        
        let previousDirectory = directoryStack.removeLast()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                // Get contents of the previous directory
                let directoryContents = try self.fileManager.contentsOfDirectory(
                    at: previousDirectory,
                    includingPropertiesForKeys: [
                        .creationDateKey,
                        .contentModificationDateKey,
                        .fileSizeKey,
                        .isDirectoryKey
                    ],
                    options: .skipsHiddenFiles
                )
                
                // Create File objects
                var folderFiles: [File] = []
                for fileURL in directoryContents {
                    let file = File(url: fileURL)
                    folderFiles.append(file)
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    self.fileList = folderFiles
                    self.currentDirectory = previousDirectory
                    self.sortFiles()
                    self.tableView.reloadData()
                    self.activityIndicator.stopAnimating()
                    
                    // If we're back at the root directory, reset the title
                    if self.directoryStack.isEmpty {
                        self.title = "File Nexus"
                        
                        // Remove the back button if we're at the root
                        if var rightBarItems = self.navigationItem.rightBarButtonItems {
                            rightBarItems.removeAll(where: { 
                                ($0.action == #selector(self.navigateBack)) 
                            })
                            self.navigationItem.rightBarButtonItems = rightBarItems
                        }
                    } else {
                        // Update the title to the current folder
                        self.title = previousDirectory.lastPathComponent
                    }
                    
                    // If no files, show a helpful message
                    if folderFiles.isEmpty {
                        self.showEmptyStateMessage()
                    } else {
                        self.hideEmptyStateMessage()
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    
                    self.activityIndicator.stopAnimating()
                    Debug.shared.log(message: "Directory navigation error: \(error.localizedDescription)", type: .error)
                    self.utilities.handleError(in: self, error: error, withTitle: "Folder Navigation Error")
                }
            }
        }
    }
    
    // MARK: - UITableViewDataSource
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return searchController.isActive ? filteredFileList.count : fileList.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "FileCell", for: indexPath) as? FileTableViewCell else {
            return UITableViewCell()
        }
        let file = searchController.isActive ? filteredFileList[indexPath.row] : fileList[indexPath.row]
        cell.configure(with: file)
        cell.backgroundColor = .clear
        cell.layer.cornerRadius = 10
        return cell
    }
    
    // MARK: - UITableViewDelegate
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let file = searchController.isActive ? filteredFileList[indexPath.row] : fileList[indexPath.row]
        showFileOptions(for: file)
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] (_, _, completion) in
            guard let self = self else { return }
            let file = self.searchController.isActive ? self.filteredFileList[indexPath.row] : self.fileList[indexPath.row]
            if let index = self.fileList.firstIndex(of: file) {
                self.deleteFile(at: index)
            }
            completion(true)
        }
        deleteAction.backgroundColor = .systemRed
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }
    
    // MARK: - UITableViewDragDelegate
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        let file = searchController.isActive ? filteredFileList[indexPath.row] : fileList[indexPath.row]
        let dragItem = UIDragItem(itemProvider: NSItemProvider(object: file.url.path as NSString))
        session.localContext = file.name
        return [dragItem]
    }
    
    // MARK: - UITableViewDropDelegate
    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        tableHandlers.tableView(tableView, performDropWith: coordinator, fileList: &fileList, documentsDirectory: documentsDirectory, loadFiles: loadFiles)
    }
    
    // MARK: - FileHandlingDelegate
    override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)?) {
        super.present(viewControllerToPresent, animated: flag, completion: completion)
    }
    
    // MARK: - UIDocumentPickerDelegate
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // Handle file picker dismissal without selection
        guard !urls.isEmpty, let selectedFileURL = urls.first else { 
            Debug.shared.log(message: "Document picker dismissed without selection", type: .info)
            return 
        }
        
        // Import the selected file
        handleImportedFile(url: selectedFileURL)
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Debug.shared.log(message: "Document picker was cancelled", type: .info)
    }
    
    // MARK: - Private Methods
    private func applyFuturisticTransition() {
        let transition = CATransition()
        transition.duration = 0.5
        transition.type = .push
        transition.subtype = .fromTop
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        view.layer.add(transition, forKey: nil)
    }
}

extension CALayer {
    func applyFuturisticShadow() {
        shadowColor = UIColor.systemCyan.withAlphaComponent(0.3).cgColor
        shadowOffset = CGSize(width: 0, height: 5)
        shadowRadius = 10
        shadowOpacity = 0.8
        masksToBounds = false
    }
}