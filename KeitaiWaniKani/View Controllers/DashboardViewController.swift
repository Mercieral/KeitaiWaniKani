//
//  DashboardViewController.swift
//  KeitaiWaniKani
//
//  Copyright © 2015 Chris Laverty. All rights reserved.
//

import UIKit
import WebKit
import CocoaLumberjack
import FMDB
import OperationKit
import WaniKaniKit

class DashboardViewController: UITableViewController, WebViewControllerDelegate, WKScriptMessageHandler {
    
    private struct SegueIdentifiers {
        static let radicalsProgress = "Show Radicals Progress"
        static let kanjiProgress = "Show Kanji Progress"
    }
    
    private enum TableViewSections: Int {
        case CurrentlyAvailable = 0, NextReview = 1, LevelProgress = 2, SRSDistribution = 3, Links = 4
    }
    
    // MARK: - Properties
    
    var progressDescriptionLabel: UILabel!
    var progressAdditionalDescriptionLabel: UILabel!
    var progressView: UIProgressView!
    
    private var updateUITimer: NSTimer? {
        willSet {
            updateUITimer?.invalidate()
        }
    }
    private var updateStudyQueueTimer: NSTimer? {
        willSet {
            updateStudyQueueTimer?.invalidate()
        }
    }
    
    private var userInformation: UserInformation? {
        didSet {
            if userInformation != oldValue {
                self.updateUIForUserInformation(userInformation)
            }
        }
    }
    
    private var studyQueue: StudyQueue? {
        didSet {
            if studyQueue != oldValue {
                self.updateUIForStudyQueue(studyQueue)
            }
        }
    }
    
    private var levelProgression: LevelProgression? {
        didSet {
            if levelProgression != oldValue {
                self.updateUIForLevelProgression(levelProgression)
            }
        }
    }
    
    private var srsDistribution: SRSDistribution? {
        didSet {
            if srsDistribution != oldValue {
                self.updateUIForSRSDistribution(srsDistribution)
            }
        }
    }
    
    private var apiDataNeedsRefresh: Bool {
        return ApplicationSettings.needsRefresh() || userInformation == nil || studyQueue == nil || levelProgression == nil || srsDistribution == nil
    }
    
    private var dashboardViewControllerObservationContext = 0
    private let progressObservedKeys = ["fractionCompleted", "completedUnitCount", "totalUnitCount", "localizedDescription", "localizedAdditionalDescription"]
    private var dataRefreshOperation: GetDashboardDataOperation? {
        willSet {
            guard let formerDataRefreshOperation = dataRefreshOperation else { return }
            
            let formerProgress = formerDataRefreshOperation.progress
            for overallProgressObservedKey in progressObservedKeys {
                formerProgress.removeObserver(self, forKeyPath: overallProgressObservedKey, context: &dashboardViewControllerObservationContext)
            }
            
            if formerProgress.fractionCompleted < 1 && formerProgress.cancellable {
                DDLogDebug("Cancelling incomplete operation \(formerDataRefreshOperation.UUID)")
                formerDataRefreshOperation.cancel()
            }
        }
        
        didSet {
            if let newDataRefreshOperation = dataRefreshOperation {
                refreshControl?.beginRefreshing()
                let progress = newDataRefreshOperation.progress
                for overallProgressObservedKey in progressObservedKeys {
                    progress.addObserver(self, forKeyPath: overallProgressObservedKey, options: [], context: &dashboardViewControllerObservationContext)
                }
            } else {
                refreshControl?.endRefreshing()
            }
            
            updateProgress()
        }
    }
    
    private var overallProgress: NSProgress? {
        return dataRefreshOperation?.progress
    }
    
    private var progressViewIsHidden: Bool {
        return progressView == nil || progressView?.alpha == 0
    }
    
    private let blurEffect = UIBlurEffect(style: .ExtraLight)
    
    /// Formats percentages in truncated to whole percents (as the WK dashboard does)
    private var percentFormatter: NSNumberFormatter = {
        let formatter = NSNumberFormatter()
        formatter.numberStyle = .PercentStyle
        formatter.roundingMode = .RoundDown
        formatter.roundingIncrement = 0.01
        return formatter
        }()
    
    private var databaseQueue: FMDatabaseQueue {
        let delegate = UIApplication.sharedApplication().delegate as! AppDelegate
        return delegate.databaseQueue
    }
    
    // MARK: - Outlets
    
    // MARK: Currently Available
    
    @IBOutlet weak var pendingLessonsLabel: UILabel!
    @IBOutlet weak var lessonsCell: UITableViewCell!
    @IBOutlet weak var reviewTitleLabel: UILabel!
    @IBOutlet weak var reviewCountLabel: UILabel!
    @IBOutlet weak var reviewTimeRemainingLabel: UILabel!
    @IBOutlet weak var reviewsCell: UITableViewCell!
    
    // MARK: Upcoming Reviews
    
    @IBOutlet weak var reviewsNextHourLabel: UILabel!
    @IBOutlet weak var reviewsNextDayLabel: UILabel!
    
    // MARK: Level Progress
    
    @IBOutlet weak var radicalPercentageCompletionLabel: UILabel!
    @IBOutlet weak var radicalTotalItemCountLabel: UILabel!
    @IBOutlet weak var radicalProgressView: UIProgressView!
    @IBOutlet weak var kanjiPercentageCompletionLabel: UILabel!
    @IBOutlet weak var kanjiTotalItemCountLabel: UILabel!
    @IBOutlet weak var kanjiProgressView: UIProgressView!
    
    // MARK: SRS Distribution
    
    @IBOutlet weak var apprenticeItemCountLabel: UILabel!
    @IBOutlet weak var guruItemCountLabel: UILabel!
    @IBOutlet weak var masterItemCountLabel: UILabel!
    @IBOutlet weak var enlightenedItemCountLabel: UILabel!
    @IBOutlet weak var burnedItemCountLabel: UILabel!

    // MARK: - Actions
    
    @IBAction func refresh(sender: UIRefreshControl) {
        fetchStudyQueueFromNetworkInBackground(forced: true)
    }
    
    // Unwind segue when web browser is dismissed
    @IBAction func forceRefreshStudyQueue(segue: UIStoryboardSegue) {
        fetchStudyQueueFromNetworkInBackground(forced: true)
    }

    // MARK: - Update UI
    
    func updateUI() {
        updateUIForStudyQueue(studyQueue)
        updateUIForLevelProgression(levelProgression)
        updateUIForUserInformation(userInformation)
        updateUIForSRSDistribution(srsDistribution)
        updateProgress()
    }
    
    // MARK: Progress
    
    func updateProgress() {
        updateProgressLabels()
        updateProgressView()
    }
    
    func updateProgressLabels() {
        assert(NSThread.isMainThread(), "Must be called on the main thread")
        
        // Description label text
        let localizedDescription = overallProgress?.localizedDescription
        if localizedDescription?.isEmpty == false {
            progressDescriptionLabel?.text = localizedDescription
        } else {
            let formattedLastRefreshTime = ApplicationSettings.lastRefreshTime.map { NSDateFormatter.localizedStringFromDate($0, dateStyle: .MediumStyle, timeStyle: .ShortStyle) } ?? "never"
            progressDescriptionLabel?.text = "Last updated: \(formattedLastRefreshTime)"
        }
        
        // Additional description label text
        if let localizedAdditionalDescription = overallProgress?.localizedAdditionalDescription {
            // Set the text only if it is non-empty.  Otherwise, keep the existing text.
            if !localizedAdditionalDescription.isEmpty {
                progressAdditionalDescriptionLabel?.text = localizedAdditionalDescription
            }
            // Update the visibility based on whether there's text in the label or not
            progressAdditionalDescriptionLabel?.hidden = progressAdditionalDescriptionLabel?.text?.isEmpty != false
        } else {
            progressAdditionalDescriptionLabel?.text = nil
            progressAdditionalDescriptionLabel?.hidden = true
        }
    }
    
    func updateProgressView() {
        assert(NSThread.isMainThread(), "Must be called on the main thread")
        guard let progressView = progressView else { return }
        
        // Progress view visibility
        let shouldHide: Bool
        let fractionCompleted: Float
        if let overallProgress = self.overallProgress {
            shouldHide = overallProgress.finished || overallProgress.cancelled
            fractionCompleted = Float(overallProgress.fractionCompleted)
        } else {
            shouldHide = true
            fractionCompleted = 0
        }
        
        if !progressViewIsHidden && shouldHide {
            UIView.animateWithDuration(0.1) {
                progressView.setProgress(1.0, animated: false)
            }
            UIView.animateWithDuration(0.2, delay: 0.1, options: [.CurveEaseIn],
                animations: {
                    progressView.alpha = 0
                },
                completion: { _ in
                    progressView.setProgress(0.0, animated: false)
            })
        } else if progressViewIsHidden && !shouldHide {
            progressView.setProgress(0.0, animated: false)
            progressView.alpha = 1.0
            progressView.setProgress(fractionCompleted, animated: true)
        } else if !progressViewIsHidden && !shouldHide {
            progressView.setProgress(fractionCompleted, animated: true)
        }
    }
    
    // MARK: Model
    
    func updateUIForStudyQueue(studyQueue: StudyQueue?) {
        assert(NSThread.isMainThread(), "Must be called on the main thread")
        
        guard let studyQueue = self.studyQueue else {
            pendingLessonsLabel.text = "–"
            lessonsCell.accessoryType = .DisclosureIndicator
            reviewTitleLabel.text = "Reviews"
            reviewCountLabel.text = "–"
            reviewTimeRemainingLabel.text = nil
            reviewsNextHourLabel.text = "–"
            reviewsNextDayLabel.text = "–"
            reviewsCell.accessoryType = .DisclosureIndicator
            return
        }
        
        setCount(studyQueue.lessonsAvailable, forLabel: pendingLessonsLabel)
        lessonsCell.accessoryType = studyQueue.lessonsAvailable > 0 ? .DisclosureIndicator : .None
        
        setCount(studyQueue.reviewsAvailableNextHour, forLabel: reviewsNextHourLabel)
        setCount(studyQueue.reviewsAvailableNextDay, forLabel: reviewsNextDayLabel)
        
        setTimeToNextReview(studyQueue)
    }
    
    private func setCount(count: Int, forLabel label: UILabel?) {
        guard let label = label else { return }
        
        label.text = NSNumberFormatter.localizedStringFromNumber(count, numberStyle: .DecimalStyle)
        label.textColor = count > 0 ? UIColor.blackColor() : UIColor.lightGrayColor()
    }
    
    func setTimeToNextReview(studyQueue: StudyQueue) {
        assert(NSThread.isMainThread(), "Must be called on the main thread")
        
        switch studyQueue.formattedTimeToNextReview() {
        case .None, .Now:
            reviewsCell.accessoryType = .DisclosureIndicator
            reviewTitleLabel.text = "Reviews"
            setCount(studyQueue.reviewsAvailable, forLabel: reviewCountLabel)
            reviewTimeRemainingLabel.text = nil
        case .FormattedString(let formattedInterval):
            reviewsCell.accessoryType = .None
            reviewTitleLabel.text = "Next Review"
            reviewCountLabel.text = studyQueue.formattedNextReviewDate()
            reviewCountLabel.textColor = UIColor.blackColor()
            reviewTimeRemainingLabel.text = formattedInterval
        case .UnformattedInterval(let secondsUntilNextReview):
            reviewsCell.accessoryType = .None
            reviewTitleLabel.text = "Next Review"
            reviewCountLabel.text = studyQueue.formattedNextReviewDate()
            reviewCountLabel.textColor = UIColor.blackColor()
            reviewTimeRemainingLabel.text = "\(NSNumberFormatter.localizedStringFromNumber(secondsUntilNextReview, numberStyle: .DecimalStyle))s"
        }
    }
    
    func updateUIForLevelProgression(levelProgression: LevelProgression?) {
        assert(NSThread.isMainThread(), "Must be called on the main thread")
        
        guard let levelProgression = self.levelProgression else {
            return
        }
        
        self.updateLevelProgressCellTo(levelProgression.radicalsProgress, ofTotal: levelProgression.radicalsTotal, percentageCompletionLabel: radicalPercentageCompletionLabel, progressView: radicalProgressView, totalItemCountLabel: radicalTotalItemCountLabel)
        self.updateLevelProgressCellTo(levelProgression.kanjiProgress, ofTotal: levelProgression.kanjiTotal, percentageCompletionLabel: kanjiPercentageCompletionLabel, progressView: kanjiProgressView, totalItemCountLabel: kanjiTotalItemCountLabel)
    }
    
    func updateUIForUserInformation(userInformation: UserInformation?) {
        assert(NSThread.isMainThread(), "Must be called on the main thread")
        
        self.tableView.reloadSections(NSIndexSet(index: TableViewSections.LevelProgress.rawValue), withRowAnimation: .None)
    }
    
    func updateLevelProgressCellTo(complete: Int, ofTotal total: Int, percentageCompletionLabel: UILabel?, progressView: UIProgressView?, totalItemCountLabel: UILabel?) {
        assert(NSThread.isMainThread(), "Must be called on the main thread")
        
        let fractionComplete = total == 0 ? 1.0 : Double(complete) / Double(total)
        let formattedFractionComplete = percentFormatter.stringFromNumber(fractionComplete) ?? "–%"
        
        percentageCompletionLabel?.text = formattedFractionComplete
        progressView?.setProgress(Float(fractionComplete), animated: true)
        totalItemCountLabel?.text = NSNumberFormatter.localizedStringFromNumber(total, numberStyle: .DecimalStyle)
    }
    
    func updateUIForSRSDistribution(srsDistribution: SRSDistribution?) {
        assert(NSThread.isMainThread(), "Must be called on the main thread")
        
        let pairs: [(SRSLevel, UILabel?)] = [
            (.Apprentice, apprenticeItemCountLabel),
            (.Guru, guruItemCountLabel),
            (.Master, masterItemCountLabel),
            (.Enlightened, enlightenedItemCountLabel),
            (.Burned, burnedItemCountLabel),
        ]
        
        for (srsLevel, label) in pairs {
            let itemCounts = srsDistribution?.countsBySRSLevel[srsLevel] ?? SRSItemCounts.zero
            let formattedCount = NSNumberFormatter.localizedStringFromNumber(itemCounts.total, numberStyle: .DecimalStyle)
            label?.text = formattedCount
        }
        
        self.tableView.reloadSections(NSIndexSet(index: TableViewSections.SRSDistribution.rawValue), withRowAnimation: .None)
    }
    
    // MARK: - Data Fetch
    
    func fetchStudyQueueFromDatabase() {
        databaseQueue.inDatabase { database in
            do {
                let userInformation = try UserInformation.coder.loadFromDatabase(database)
                let studyQueue = try StudyQueue.coder.loadFromDatabase(database)
                let levelProgression = try LevelProgression.coder.loadFromDatabase(database)
                let srsDistribution = try SRSDistribution.coder.loadFromDatabase(database)
                dispatch_async(dispatch_get_main_queue()) {
                    self.userInformation = userInformation
                    self.studyQueue = studyQueue
                    self.levelProgression = levelProgression
                    self.srsDistribution = srsDistribution
                    self.updateProgress()
                    
                    DDLogDebug("Fetch of latest StudyQueue (\(studyQueue?.lastUpdateTimestamp)) from database complete.  Needs refreshing? \(self.apiDataNeedsRefresh)")
                    if self.apiDataNeedsRefresh {
                        self.updateStudyQueueTimer?.fire()
                    }
                }
            } catch {
                // Database errors are fatal
                fatalError("DashboardViewController: Failed to fetch latest study queue due to error: \(error)")
            }
        }
    }
    
    func fetchStudyQueueFromNetwork(forced forced: Bool, afterDelay delay: NSTimeInterval? = nil) {
        guard let apiKey = ApplicationSettings.apiKey else {
            fatalError("API Key must be set to fetch study queue")
        }
        
        if !forced && self.dataRefreshOperation != nil {
            DDLogInfo("Not restarting study queue refresh as an operation is already running and force flag not set")
            return
        }

        DDLogInfo("Checking whether study queue needs refreshed (forced? \(forced))")
        let delegate = UIApplication.sharedApplication().delegate as! AppDelegate
        let databaseQueue = delegate.databaseQueue
        let resolver = WaniKaniAPI.resourceResolverForAPIKey(apiKey)
        let operation = GetDashboardDataOperation(resolver: resolver, databaseQueue: databaseQueue, forcedFetch: forced, initialDelay: delay)
        
        // Study queue
        let studyQueueObserver = BlockObserver { [weak self] _ in
            databaseQueue.inDatabase { database in
                let userInformation = try! UserInformation.coder.loadFromDatabase(database)
                let studyQueue = try! StudyQueue.coder.loadFromDatabase(database)
                dispatch_async(dispatch_get_main_queue()) {
                    self?.userInformation = userInformation
                    self?.studyQueue = studyQueue
                }
            }
        }
        
        operation.studyQueueOperation.addObserver(studyQueueObserver)
        
        // Level progression
        let levelProgressionObserver = BlockObserver { [weak self] _ in
            databaseQueue.inDatabase { database in
                let levelProgression = try! LevelProgression.coder.loadFromDatabase(database)
                dispatch_async(dispatch_get_main_queue()) {
                    self?.levelProgression = levelProgression
                }
            }
        }
        
        operation.levelProgressionOperation.addObserver(levelProgressionObserver)
        
        // SRS Distribution
        let srsDistributionObserver = BlockObserver { [weak self] _ in
            databaseQueue.inDatabase { database in
                let srsDistribution = try! SRSDistribution.coder.loadFromDatabase(database)
                dispatch_async(dispatch_get_main_queue()) {
                    self?.srsDistribution = srsDistribution
                }
            }
        }
        
        operation.srsDistributionOperation.addObserver(srsDistributionObserver)
        
        // Operation finish
        let observer = BlockObserver(
            startHandler: { operation in
                DDLogInfo("Fetching study queue for API key \(apiKey) (request ID \(operation.UUID))...")
            },
            finishHandler: { [weak self] (operation, errors) in
                let fatalErrors = errors.filterNonFatalErrors()
                DDLogInfo("Study queue fetch for API key \(apiKey) complete (request ID \(operation.UUID)): \(fatalErrors)")
                let operation = operation as! GetDashboardDataOperation
                dispatch_async(dispatch_get_main_queue()) {
                    // If this operation represents the currently tracked operation, then set to nil to mark as done
                    if operation === self?.dataRefreshOperation {
                        self?.dataRefreshOperation = nil
                    }
                }
            })
        operation.addObserver(observer)
        DDLogInfo("Enqueuing fetch of latest study queue")
        
        delegate.operationQueue.addOperation(operation)
        
        dispatch_async(dispatch_get_main_queue()) { [weak self] in
            self?.dataRefreshOperation = operation
        }
    }
    
    func fetchStudyQueueFromNetworkInBackground(forced forced: Bool, afterDelay delay: NSTimeInterval? = nil) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)) { [weak self] in
            self?.fetchStudyQueueFromNetwork(forced: forced, afterDelay: delay)
        }
    }
    
    // MARK: - Timer Callbacks

    func updateUITimerDidFire(timer: NSTimer) {
        guard let studyQueue = self.studyQueue else {
            return
        }
        
        setTimeToNextReview(studyQueue)
    }
    
    func updateStudyQueueTimerDidFire(timer: NSTimer) {
        // Don't schedule another fetch if one is still running
        guard self.overallProgress?.finished ?? true else { return }
        fetchStudyQueueFromNetworkInBackground(forced: false)
    }
    
    func startTimers() {
        DDLogDebug("Starting dashboard timers")
        updateUITimer = {
            // Find out when the start of the next minute is
            let referenceDate = NSDate()
            let calendar = NSCalendar.autoupdatingCurrentCalendar()
            let components = NSDateComponents()
            components.second = -calendar.component(.Second, fromDate: referenceDate)
            components.minute = 1
            // Schedule timer for the top of every minute
            let nextFireTime = calendar.dateByAddingComponents(components, toDate: referenceDate, options: [])!
            let timer = NSTimer(fireDate: nextFireTime, interval: 60, target: self, selector: "updateUITimerDidFire:", userInfo: nil, repeats: true)
            timer.tolerance = 1
            NSRunLoop.mainRunLoop().addTimer(timer, forMode: NSDefaultRunLoopMode)
            return timer
            }()
        updateStudyQueueTimer = {
            let nextFetchTime = WaniKaniAPI.nextRefreshTimeFromNow()
            
            DDLogInfo("Will fetch study queue at \(nextFetchTime)")
            let timer = NSTimer(fireDate: nextFetchTime, interval: NSTimeInterval(WaniKaniAPI.updateMinuteCount * 60), target: self, selector: "updateStudyQueueTimerDidFire:", userInfo: nil, repeats: true)
            timer.tolerance = 20
            NSRunLoop.mainRunLoop().addTimer(timer, forMode: NSDefaultRunLoopMode)
            return timer
            }()
        
        // Database could have been updated from a background fetch.  Refresh it now in case.
        DDLogDebug("Enqueuing fetch of latest StudyQueue from database")
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)) {
            self.fetchStudyQueueFromDatabase()
        }
    }
    
    func killTimers() {
        DDLogDebug("Killing dashboard timers")
        updateUITimer = nil
        updateStudyQueueTimer = nil
    }
    
    // MARK: - WebViewControllerDelegate
    
    func webViewControllerDidFinish(controller: WebViewController) {
        controller.dismissViewControllerAnimated(true, completion: nil)
        if controller.URL == WaniKaniURLs.reviewSession || controller.URL == WaniKaniURLs.lessonSession {
            fetchStudyQueueFromNetworkInBackground(forced: true, afterDelay: 2)
        }
    }
    
    // MARK: - UITableViewDelegate

    override func tableView(tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 44.0
    }
    
    override func tableView(tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let tableViewSection = TableViewSections(rawValue: section) else {
            fatalError("Invalid section index \(section) requested")
        }
        
        let label = UILabel(frame: CGRect(x: 10, y: 0, width: tableView.bounds.size.width - 10, height: 44))
        label.autoresizingMask = .FlexibleWidth
        label.backgroundColor = UIColor.clearColor()
        label.opaque = false
        label.textColor = UIColor.whiteColor()
        label.font = UIFont.preferredFontForTextStyle(UIFontTextStyleHeadline)
        let visualEffectVibrancyView = UIVisualEffectView(effect: UIVibrancyEffect(forBlurEffect: blurEffect))
        visualEffectVibrancyView.autoresizingMask = .FlexibleWidth
        visualEffectVibrancyView.frame = CGRect(x: 0, y: 0, width: tableView.bounds.size.width, height: 44)
        visualEffectVibrancyView.contentView.addSubview(label)
        
        switch tableViewSection {
        case .CurrentlyAvailable: label.text = "Currently Available"
        case .NextReview: label.text = "Upcoming Reviews"
        case .LevelProgress:
            if let level = userInformation?.level {
                label.text = "Level \(level) Progress"
            } else {
                label.text = "Level Progress"
            }
        case .SRSDistribution: label.text = "SRS Item Distribution"
        case .Links: label.text = "Links"
        }
        
        return visualEffectVibrancyView
    }
    
    override func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        guard let tableViewSection = TableViewSections(rawValue: indexPath.section) else {
            fatalError("Invalid section index \(indexPath.section) requested")
        }

        switch (tableViewSection, indexPath.row) {
        case (.CurrentlyAvailable, 0): // Lessons
            let vc = WebViewController.forURL(WaniKaniURLs.lessonSession, configBlock: webViewControllerCommonConfiguration)
            if self.dataRefreshOperation != nil {
                // Cancel data refresh operation because we're just going to restart it when the web view is dismissed
                DDLogDebug("Cancelling data refresh operation")
                self.dataRefreshOperation = nil
            }
            presentViewController(vc, animated: true, completion: nil)
        case (.CurrentlyAvailable, 1): // Reviews
            let vc = WebViewController.forURL(WaniKaniURLs.reviewSession, configBlock: webViewControllerCommonConfiguration)
            if self.dataRefreshOperation != nil {
                // Cancel data refresh operation because we're just going to restart it when the web view is dismissed
                DDLogDebug("Cancelling data refresh operation")
                self.dataRefreshOperation = nil
            }
            presentViewController(vc, animated: true, completion: nil)
        case (.Links, 0): // Web Dashboard
            let vc = WebViewController.forURL(WaniKaniURLs.dashboard, configBlock: webViewControllerCommonConfiguration)
            presentViewController(vc, animated: true, completion: nil)
        case (.Links, 1): // Community Centre
            let vc = WebViewController.forURL(WaniKaniURLs.communityCentre, configBlock: webViewControllerCommonConfiguration)
            presentViewController(vc, animated: true, completion: nil)
        default: break
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(userContentController: WKUserContentController, didReceiveScriptMessage message: WKScriptMessage) {
        DDLogDebug("Received script message body \(message.body)")
    }
    
    // MARK: - View Controller Lifecycle
    
    override func loadView() {
        super.loadView()
        
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "didEnterBackground:", name: UIApplicationDidEnterBackgroundNotification, object: nil)
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "didEnterForeground:", name: UIApplicationDidBecomeActiveNotification, object: nil)

        let backgroundView = UIView(frame: tableView.frame)
        let imageView = UIImageView(image: UIImage(named: "Header"))
        imageView.contentMode = .ScaleAspectFill
        imageView.frame = backgroundView.frame
        backgroundView.addSubview(imageView)
        let visualEffectBlurView = UIVisualEffectView(effect: blurEffect)
        visualEffectBlurView.frame = imageView.frame
        visualEffectBlurView.autoresizingMask = [ .FlexibleHeight, .FlexibleWidth ]
        backgroundView.addSubview(visualEffectBlurView)
        tableView.backgroundView = backgroundView
        tableView.separatorEffect = UIVibrancyEffect(forBlurEffect: blurEffect)

        // Ensure the refresh control is positioned on top of the background view
        if let refreshControl = self.refreshControl where refreshControl.layer.zPosition <= tableView.backgroundView!.layer.zPosition {
            tableView.backgroundView!.layer.zPosition = refreshControl.layer.zPosition - 1
        }
        
        if let toolbar = self.navigationController?.toolbar {
            progressView = UIProgressView(progressViewStyle: .Default)
            progressView.translatesAutoresizingMaskIntoConstraints = false
            progressView.trackTintColor = UIColor.clearColor()
            progressView.progress = 0
            progressView.alpha = 0
            toolbar.addSubview(progressView)
            NSLayoutConstraint(item: progressView, attribute: .Top, relatedBy: .Equal, toItem: toolbar, attribute: .Top, multiplier: 1, constant: 0).active = true
            NSLayoutConstraint(item: progressView, attribute: .Leading, relatedBy: .Equal, toItem: toolbar, attribute: .Leading, multiplier: 1, constant: 0).active = true
            NSLayoutConstraint(item: progressView, attribute: .Trailing, relatedBy: .Equal, toItem: toolbar, attribute: .Trailing, multiplier: 1, constant: 0).active = true
            
            var items = self.toolbarItems ?? []
            
            items.append(UIBarButtonItem(barButtonSystemItem: .FlexibleSpace, target: nil, action: nil))
            
            let toolbarView = UIView(frame: toolbar.bounds)
            toolbarView.autoresizingMask = [.FlexibleHeight, .FlexibleWidth]
            let statusView = UIView(frame: CGRect.zero)
            statusView.translatesAutoresizingMaskIntoConstraints = false
            toolbarView.addSubview(statusView)
            NSLayoutConstraint(item: statusView, attribute: .CenterX, relatedBy: .Equal, toItem: toolbarView, attribute: .CenterX, multiplier: 1, constant: 0).active = true
            NSLayoutConstraint(item: statusView, attribute: .CenterY, relatedBy: .Equal, toItem: toolbarView, attribute: .CenterY, multiplier: 1, constant: 0).active = true
            
            progressDescriptionLabel = UILabel()
            progressDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
            progressDescriptionLabel.font = UIFont.preferredFontForTextStyle(UIFontTextStyleCaption2)
            progressDescriptionLabel.backgroundColor = UIColor.clearColor()
            progressDescriptionLabel.textColor = UIColor.blackColor()
            progressDescriptionLabel.textAlignment = .Center
            statusView.addSubview(progressDescriptionLabel)
            NSLayoutConstraint(item: progressDescriptionLabel, attribute: .Top, relatedBy: .Equal, toItem: statusView, attribute: .Top, multiplier: 1, constant: 0).active = true
            NSLayoutConstraint(item: progressDescriptionLabel, attribute: .Leading, relatedBy: .Equal, toItem: statusView, attribute: .Leading, multiplier: 1, constant: 0).active = true
            NSLayoutConstraint(item: progressDescriptionLabel, attribute: .Trailing, relatedBy: .Equal, toItem: statusView, attribute: .Trailing, multiplier: 1, constant: 0).active = true
            NSLayoutConstraint(item: progressDescriptionLabel, attribute: .Bottom, relatedBy: .LessThanOrEqual, toItem: statusView, attribute: .Bottom, multiplier: 1, constant: 0).active = true
            
            progressAdditionalDescriptionLabel = UILabel()
            progressAdditionalDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
            progressAdditionalDescriptionLabel.font = UIFont.preferredFontForTextStyle(UIFontTextStyleCaption2)
            progressAdditionalDescriptionLabel.backgroundColor = UIColor.clearColor()
            progressAdditionalDescriptionLabel.textColor = UIColor.darkGrayColor()
            progressAdditionalDescriptionLabel.textAlignment = .Center
            statusView.addSubview(progressAdditionalDescriptionLabel)
            NSLayoutConstraint(item: progressAdditionalDescriptionLabel, attribute: .Leading, relatedBy: .Equal, toItem: statusView, attribute: .Leading, multiplier: 1, constant: 0).active = true
            NSLayoutConstraint(item: progressAdditionalDescriptionLabel, attribute: .Trailing, relatedBy: .Equal, toItem: statusView, attribute: .Trailing, multiplier: 1, constant: 0).active = true
            NSLayoutConstraint(item: progressAdditionalDescriptionLabel, attribute: .Bottom, relatedBy: .Equal, toItem: statusView, attribute: .Bottom, multiplier: 1, constant: 0).active = true
            NSLayoutConstraint(item: progressAdditionalDescriptionLabel, attribute: .Top, relatedBy: .Equal, toItem: progressDescriptionLabel, attribute: .Bottom, multiplier: 1, constant: 0).active = true

            let statusViewBarButtonItem = UIBarButtonItem(customView: toolbarView)
            items.append(statusViewBarButtonItem)
            
            items.append(UIBarButtonItem(barButtonSystemItem: .FlexibleSpace, target: nil, action: nil))
            
            self.setToolbarItems(items, animated: false)
        }
        
        updateUI()
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }
    
    override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)

        guard let apiKey = ApplicationSettings.apiKey where !apiKey.isEmpty else {
            DDLogInfo("Dashboard view has no API key.  Dismissing back to home screen.")
            dismissViewControllerAnimated(false, completion: nil)
            return
        }
    }
    
    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        
        // The view will be dismissed if there's no API key set (possibly because it was cleared in app settings)
        // Don't bother starting timers in this case.
        guard let apiKey = ApplicationSettings.apiKey where !apiKey.isEmpty else {
            DDLogInfo("Dashboard view has no API key.  Not starting timers.")
            return
        }
        
        startTimers()
        updateUI()
    }
    
    override func viewWillDisappear(animated: Bool) {
        super.viewWillDisappear(animated)
        
        killTimers()
    }
    
    override func prepareForSegue(segue: UIStoryboardSegue, sender: AnyObject?) {
        guard let identifier = segue.identifier else {
            return
        }
        
        switch identifier {
        case SegueIdentifiers.radicalsProgress:
            if let vc = segue.destinationContentViewController as? SRSDataItemCollectionViewController {
                self.databaseQueue.inDatabase { database in
                    do {
                        if let userInformation = try UserInformation.coder.loadFromDatabase(database) {
                            let radicals = try Radical.coder.loadFromDatabase(database, forLevel: userInformation.level)
                            vc.setSRSDataItems(radicals.map { $0 as SRSDataItem }, withTitle: "Radicals")
                        }
                    } catch {
                        DDLogWarn("Failed to get radicals for current level: \(error)")
                    }
                }
            }
        case SegueIdentifiers.kanjiProgress:
            if let vc = segue.destinationContentViewController as? SRSDataItemCollectionViewController {
                self.databaseQueue.inDatabase { database in
                    do {
                        if let userInformation = try UserInformation.coder.loadFromDatabase(database) {
                            let kanji = try Kanji.coder.loadFromDatabase(database, forLevel: userInformation.level)
                            vc.setSRSDataItems(kanji.map { $0 as SRSDataItem }, withTitle: "Kanji")
                        }
                    } catch {
                        DDLogWarn("Failed to get radicals for current level: \(error)")
                    }
                }
            }
        default: break
        }
    }
    
    private func webViewControllerCommonConfiguration(webViewController: WebViewController) {
        webViewController.webViewConfiguration.userContentController.addUserScript(getUserScript("common"))
        if ApplicationSettings.userScriptIgnoreAnswerEnabled {
            webViewController.webViewConfiguration.userContentController.addUserScript(getUserScript("wkoverride.user"))
        }
        webViewController.webViewConfiguration.userContentController.addScriptMessageHandler(self, name: "debuglog")
        webViewController.delegate = self
    }
    
    private func getUserScript(name: String) -> WKUserScript {
        guard let scriptURL = NSBundle.mainBundle().URLForResource("\(name)", withExtension: "js") else {
            fatalError("Count not find user script \(name).js in main bundle")
        }
        let scriptSource = try! String(contentsOfURL: scriptURL)
        return WKUserScript(source: scriptSource, injectionTime: .AtDocumentEnd, forMainFrameOnly: true)
    }
    
    // MARK: - Background transition
    
    func didEnterBackground(notification: NSNotification) {
        killTimers()
    }
    
    func didEnterForeground(notification: NSNotification) {
        startTimers()
        updateUI()
    }

    // MARK: - Key-Value Observing
    
    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        guard context == &dashboardViewControllerObservationContext else {
            super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
            return
        }
        
        dispatch_async(dispatch_get_main_queue()) {
            self.updateProgress()
        }
    }
}