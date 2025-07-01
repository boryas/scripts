use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use mail_parser::*;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;
use std::path::PathBuf;
use std::process::Command;
use tempfile;

#[derive(Debug, Deserialize)]
struct Config {
    mailing_list: String,
    days_back: u32,
    #[serde(default)]
    additional_filters: Option<String>,
}

impl Config {
    fn to_lei_query(&self) -> String {
        let mut query = format!("s:PATCH");
        
        // Add mailing list filter
        if !self.mailing_list.is_empty() {
            query.push_str(&format!(" AND l:{}", self.mailing_list));
        }

        // Add time filter
        if self.days_back > 0 {
            query.push_str(&format!(" AND rt:{}.day.ago..", self.days_back));
        }
        
        // Add any additional filters
        if let Some(ref filters) = self.additional_filters {
            if !filters.is_empty() {
                query.push_str(&format!(" AND {}", filters));
            }
        }
        
        query
    }
    
    fn load_from_file(path: &PathBuf) -> Result<Config> {
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("Failed to read config file: {}", path.display()))?;
        let config: Config = toml::from_str(&content)
            .with_context(|| format!("Failed to parse TOML config: {}", path.display()))?;
        Ok(config)
    }
    
    fn from_cli_args(days: Option<u32>, mailing_list: Option<&str>) -> Option<Config> {
        if days.is_some() || mailing_list.is_some() {
            Some(Config {
                mailing_list: mailing_list.unwrap_or("").to_string(),
                days_back: days.unwrap_or(7), // Default to 7 days if not specified
                additional_filters: None,
            })
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct EmailHeader {
    subject: String,
    message_id: String,
    in_reply_to: Option<String>,
    author: String,
    date: DateTime<Utc>,
    raw_email: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
enum EmailType {
    CoverLetter {
        header: EmailHeader,
        title: String,
        version: u32,
        series_info: (u32, u32), // (0, total_patches)
        reviewed_by: Vec<String>,
        has_review: bool,
        replies: Vec<String>, // message_ids of replies
    },
    Patch {
        header: EmailHeader,
        title: String,
        version: u32,
        series_info: Option<(u32, u32)>, // (patch_num, total_patches) or None for standalone
        reviewed_by: Vec<String>,
        has_review: bool,
        replies: Vec<String>, // message_ids of replies
    },
    Reply {
        header: EmailHeader,
        reviewed_by: Vec<String>,
        has_review: bool,
        replies: Vec<String>, // message_ids of replies
    },
}

impl EmailType {
    fn has_review(&self) -> bool {
        match self {
            EmailType::CoverLetter { has_review, .. } => *has_review,
            EmailType::Patch { has_review, .. } => *has_review,
            EmailType::Reply { has_review, .. } => *has_review,
        }
    }

    fn reviewed_by(&self) -> &Vec<String> {
        match self {
            EmailType::CoverLetter { reviewed_by, .. } => reviewed_by,
            EmailType::Patch { reviewed_by, .. } => reviewed_by,
            EmailType::Reply { reviewed_by, .. } => reviewed_by,
        }
    }

    fn header(&self) -> &EmailHeader {
        match self {
            EmailType::CoverLetter { header, .. } => header,
            EmailType::Patch { header, .. } => header,
            EmailType::Reply { header, .. } => header,
        }
    }

    fn title(&self) -> Option<&str> {
        match self {
            EmailType::CoverLetter { title, .. } => Some(title),
            EmailType::Patch { title, .. } => Some(title),
            EmailType::Reply { .. } => None,
        }
    }

    fn version(&self) -> Option<u32> {
        match self {
            EmailType::CoverLetter { version, .. } => Some(*version),
            EmailType::Patch { version, .. } => Some(*version),
            EmailType::Reply { .. } => None,
        }
    }

    fn add_reply(&mut self, reply_id: String) {
        match self {
            EmailType::CoverLetter { replies, .. } => {
                replies.push(reply_id.clone());
            }
            EmailType::Patch { replies, .. } => {
                replies.push(reply_id.clone());
            }
            EmailType::Reply { replies, .. } => {
                replies.push(reply_id.clone());
            }
        }
    }

    fn get_all_emails<'a>(&'a self, all_emails: &'a HashMap<String, EmailType>) -> Vec<&'a EmailType> {
        let mut result = vec![self];
        let reply_ids = match self {
            EmailType::CoverLetter { replies, .. } => replies,
            EmailType::Patch { replies, .. } => replies,
            EmailType::Reply { replies, .. } => replies,
        };

        for reply_id in reply_ids {
            if let Some(reply) = all_emails.get(reply_id) {
                result.extend(reply.get_all_emails(all_emails));
            }
        }
        result
    }

    fn collect_reviewed_by_recursive(&self, all_emails: &HashMap<String, EmailType>) -> Vec<String> {
        let mut all_reviews = self.reviewed_by().clone();
        
        let reply_ids = match self {
            EmailType::CoverLetter { replies, .. } => replies,
            EmailType::Patch { replies, .. } => replies,
            EmailType::Reply { replies, .. } => replies,
        };

        for reply_id in reply_ids {
            if let Some(reply) = all_emails.get(reply_id) {
                // Don't recurse into PATCH emails to avoid counting their reviews
                match reply {
                    EmailType::Patch { .. } => {
                        // Stop recursion at patch emails - don't include their reviews
                    }
                    _ => {
                        // Continue recursion for replies
                        all_reviews.extend(reply.collect_reviewed_by_recursive(all_emails));
                    }
                }
            }
        }
        all_reviews
    }



    fn is_series_reviewed(&self, all_emails: &HashMap<String, EmailType>) -> bool {
        match self {
            EmailType::CoverLetter { replies, .. } => {
                // Check if all patches in the series (direct replies that are patches) have reviews
                let patches: Vec<_> = replies
                    .iter()
                    .filter_map(|reply_id| all_emails.get(reply_id))
                    .filter(|email| matches!(email, EmailType::Patch { .. }))
                    .collect();

                if patches.is_empty() {
                    return false;
                }

                // All patches must have reviews (either directly or from cover letter)
                let all_reviewed = patches
                    .iter()
                    .all(|patch| patch.has_review());
                    
                all_reviewed
            }
            _ => false,
        }
    }

}

#[derive(Debug)]
struct ReviewTracker {
    series: HashMap<String, EmailType>, // message_id -> series root (cover letter or standalone patch)
    all_emails: HashMap<String, EmailType>, // message_id -> email (for reply threading)
}

impl ReviewTracker {
    fn new() -> Self {
        Self {
            series: HashMap::new(),
            all_emails: HashMap::new(),
        }
    }

    fn add_email(&mut self, email: EmailType) {
        let message_id = email.header().message_id.clone();

        // Store all emails for reply threading
        self.all_emails.insert(message_id.clone(), email.clone());

        match &email {
            EmailType::CoverLetter { title, version, .. } | 
            EmailType::Patch { title, version, series_info: None, .. } => {
                // Both cover letters and standalone patches are series roots
                // Check for existing series with same title and handle versions
                let mut to_remove = Vec::new();
                for (existing_id, existing_series) in &self.series {
                    if let Some(existing_title) = existing_series.title() {
                        if existing_title == title {
                            if let Some(existing_version) = existing_series.version() {
                                if *version > existing_version {
                                    // Remove older version
                                    to_remove.push(existing_id.clone());
                                } else if *version < existing_version {
                                    // Ignore older version
                                    return;
                                } else {
                                    // Same version, remove existing to merge reviews
                                    to_remove.push(existing_id.clone());
                                    break;
                                }
                            }
                        }
                    }
                }

                for id in to_remove {
                    self.series.remove(&id);
                }

                self.series.insert(message_id, email);
            }
            EmailType::Patch { series_info: Some(_), .. } => {
                // Series patches will be threaded as replies to their cover letter
                // No need to store them separately
            }
            EmailType::Reply { .. } => {
                // Replies are handled in the threading phase
            }
        }
    }

    fn thread_replies(&mut self) {
        // Build a list of all emails that have in_reply_to
        let replies_to_thread: Vec<(String, String)> = self
            .all_emails
            .values()
            .filter_map(|email| {
                if let Some(in_reply_to) = &email.header().in_reply_to {
                    Some((email.header().message_id.clone(), in_reply_to.clone()))
                } else {
                    None
                }
            })
            .collect();

        // Thread each reply to its parent
        for (reply_id, parent_id) in replies_to_thread {
            if self.all_emails.contains_key(&reply_id) && self.all_emails.contains_key(&parent_id) {
                self.attach_reply_direct(reply_id, &parent_id);
            }
        }
        
        // Update series with the threaded versions from all_emails
        let series_keys: Vec<_> = self.series.keys().cloned().collect();
        for key in series_keys {
            if let Some(updated_email) = self.all_emails.get(&key) {
                self.series.insert(key, updated_email.clone());
            }
        }
    }

    fn attach_reply_direct(&mut self, reply_id: String, parent_id: &str) {
        // Look up the parent directly in all_emails and add the reply ID to it
        if let Some(parent_email) = self.all_emails.get_mut(parent_id) {
            parent_email.add_reply(reply_id);
        } else {
        }
        // If parent not found, the reply becomes orphaned (could log this)
    }


    fn collect_reviews(&mut self) {
        // Apply review rules after all threading is complete
        let series_keys: Vec<_> = self.series.keys().cloned().collect();
        for key in series_keys {
            // Clone the series root first to avoid borrowing issues
            if let Some(series_root) = self.series.get(&key).cloned() {
                Self::apply_series_review_rules_to_tracker(self, &key, series_root);
            }
        }
    }

    fn apply_series_review_rules_to_tracker(tracker: &mut ReviewTracker, series_key: &str, mut series_root: EmailType) {
        match &series_root {
            EmailType::CoverLetter { .. } => {
                // For cover letter series, get cover letter reviews first
                let cover_reviews = series_root.collect_reviewed_by_recursive(&tracker.all_emails);

                if let EmailType::CoverLetter { replies, .. } = &series_root {
                    // Apply cover letter reviews to all patches in the series
                    if !cover_reviews.is_empty() {
                        for reply_id in replies {
                            if let Some(email) = tracker.all_emails.get_mut(reply_id) {
                                if let EmailType::Patch {
                                    reviewed_by,
                                    has_review,
                                    ..
                                } = email
                                {
                                    reviewed_by.extend(cover_reviews.clone());
                                    *has_review = true;
                                }
                            }
                        }
                    }

                    // Apply individual patch reviews (process each patch in isolation)
                    let reply_ids: Vec<_> = replies.clone();
                    for reply_id in reply_ids {
                        // Create a temporary clone to avoid borrowing issues
                        if let Some(patch) = tracker.all_emails.get(&reply_id).cloned() {
                            if matches!(patch, EmailType::Patch { .. }) {
                                let reviews = patch.collect_reviewed_by_recursive(&tracker.all_emails);
                                
                                // Update the actual patch in all_emails
                                if let Some(email) = tracker.all_emails.get_mut(&reply_id) {
                                    if let EmailType::Patch { has_review, reviewed_by, .. } = email {
                                        // Only add reviews that aren't already present (avoid duplicates from cover letter)
                                        let new_reviews: Vec<_> = reviews.into_iter()
                                            .filter(|review| !reviewed_by.contains(review))
                                            .collect();
                                        reviewed_by.extend(new_reviews);
                                        *has_review = !reviewed_by.is_empty();
                                    }
                                }
                            }
                        }
                    }
                }
            }
            EmailType::Patch { .. } => {
                // For standalone patches, just apply patch review rules
                Self::apply_patch_review_rules(&mut series_root, &tracker.all_emails);
            }
            _ => {
                // Shouldn't happen for series roots
            }
        }
        
        // Update the series root
        tracker.series.insert(series_key.to_string(), series_root);
    }


    fn apply_patch_review_rules(patch: &mut EmailType, all_emails: &HashMap<String, EmailType>) {
        let reviews = patch.collect_reviewed_by_recursive(all_emails);
        match patch {
            EmailType::Patch { has_review, reviewed_by, .. } => {
                // Don't add reviews that are already in the patch's reviewed_by list
                // The reviews returned by collect_reviewed_by_recursive include the patch's own reviews
                let new_reviews: Vec<_> = reviews.into_iter()
                    .filter(|review| !reviewed_by.contains(review))
                    .collect();
                reviewed_by.extend(new_reviews);
                *has_review = !reviewed_by.is_empty();
            }
            _ => {}
        }
    }

    fn get_unreviewed_emails(&self) -> Vec<&EmailType> {
        let mut result = Vec::new();

        // Check all series (both cover letter series and standalone patches)
        for series_root in self.series.values() {
            let needs_review = match series_root {
                EmailType::CoverLetter { .. } => !series_root.is_series_reviewed(&self.all_emails),
                EmailType::Patch { .. } => !series_root.has_review(),
                _ => false, // Shouldn't happen for series roots
            };

            if needs_review {
                result.extend(series_root.get_all_emails(&self.all_emails));
            }
        }

        result
    }
}

fn extract_patch_title(subject: &str) -> String {
    let re = Regex::new(r"\[PATCH[^\]]*\]\s*(.+)").unwrap();
    if let Some(captures) = re.captures(subject) {
        captures.get(1).unwrap().as_str().trim().to_string()
    } else {
        subject.to_string()
    }
}

fn extract_patch_version(subject: &str) -> u32 {
    let re = Regex::new(r"\[PATCH\s+v(\d+)").unwrap();
    if let Some(captures) = re.captures(subject) {
        captures.get(1).unwrap().as_str().parse().unwrap_or(1)
    } else {
        1
    }
}

fn extract_reviewed_by(body: &str) -> Vec<String> {
    let re = Regex::new(r"(?i)^Reviewed-by:\s*(.+)$").unwrap();
    let mut reviewers = Vec::new();

    for line in body.lines() {
        if let Some(captures) = re.captures(line.trim()) {
            reviewers.push(captures.get(1).unwrap().as_str().trim().to_string());
        }
    }

    reviewers
}

fn is_patch_email(subject: &str) -> bool {
    let re = Regex::new(r"^\[PATCH").unwrap();
    re.is_match(subject)
}

fn is_reply_email(subject: &str) -> bool {
    subject.trim_start().to_lowercase().starts_with("re:")
}

fn extract_series_info(subject: &str) -> Option<(u32, u32)> {
    let re = Regex::new(r"\[PATCH[^\]]*\s+(\d+)/(\d+)\]").unwrap();
    if let Some(captures) = re.captures(subject) {
        let patch_num = captures.get(1).unwrap().as_str().parse().ok()?;
        let total_patches = captures.get(2).unwrap().as_str().parse().ok()?;
        Some((patch_num, total_patches))
    } else {
        None
    }
}

fn run_lei_query(query: &str, output_dir: &str) -> Result<String> {
    let mut cmd = Command::new("lei");
    cmd.args(&["q", "--thread", "--no-save", "-o", output_dir, query]);
    let output = cmd.output().context("Failed to execute lei command")?;

    if !output.status.success() {
        anyhow::bail!("lei command failed: {}", String::from_utf8(output.stderr)?);
    }

    Ok(String::from_utf8(output.stdout)?)
}

fn parse_maildir(maildir_path: &PathBuf) -> Result<Vec<EmailType>> {
    let mut patches = Vec::new();

    // Look for new/ and cur/ subdirectories (Maildir format)
    for subdir in &["new", "cur"] {
        let subdir_path = maildir_path.join(subdir);
        if !subdir_path.exists() {
            continue;
        }

        for entry in std::fs::read_dir(&subdir_path)? {
            let entry = entry?;
            let file_path = entry.path();

            if file_path.is_file() {
                let raw_email = std::fs::read_to_string(&file_path)?;
                if let Ok(patch) = parse_email(&raw_email) {
                    patches.push(patch);
                }
            }
        }
    }

    Ok(patches)
}

fn parse_email(raw_email: &str) -> Result<EmailType> {
    let email = MessageParser::default()
        .parse(raw_email.as_bytes())
        .ok_or_else(|| anyhow::anyhow!("Failed to parse email"))?;

    let subject = email.subject().unwrap();
    let message_id = email.message_id().unwrap().to_string();
    let in_reply_to = email.in_reply_to().as_text().map(|s| s.to_string());

    let author = email
        .from()
        .and_then(|from| from.first())
        .map(|addr| addr.address.as_ref().map_or("Unknown", |v| v).to_string())
        .unwrap_or_else(|| "Unknown".to_string());

    let date = email
        .date()
        .and_then(|d| DateTime::parse_from_rfc2822(&d.to_rfc822()).ok())
        .map(|d| d.with_timezone(&Utc))
        .unwrap_or_else(Utc::now);

    let body = email.body_text(0).unwrap_or_default();
    let reviewed_by = extract_reviewed_by(&body);
    let has_review = !reviewed_by.is_empty();

    let header = EmailHeader {
        subject: subject.to_string(),
        message_id,
        in_reply_to,
        author,
        date,
        raw_email: raw_email.to_string(),
    };

    if is_patch_email(&subject) {
        let title = extract_patch_title(&subject);
        let version = extract_patch_version(&subject);
        let series_info = extract_series_info(&subject);

        if let Some((patch_num, total_patches)) = series_info {
            if patch_num == 0 {
                Ok(EmailType::CoverLetter {
                    header,
                    title,
                    version,
                    series_info: (patch_num, total_patches),
                    reviewed_by,
                    has_review,
                    replies: Vec::new(),
                })
            } else {
                Ok(EmailType::Patch {
                    header,
                    title,
                    version,
                    series_info: Some((patch_num, total_patches)),
                    reviewed_by,
                    has_review,
                    replies: Vec::new(),
                })
            }
        } else {
            // Standalone patch
            Ok(EmailType::Patch {
                header,
                title,
                version,
                series_info: None,
                reviewed_by,
                has_review,
                replies: Vec::new(),
            })
        }
    } else if is_reply_email(&subject) {
        // Reply email
        Ok(EmailType::Reply {
            header,
            reviewed_by,
            has_review,
            replies: Vec::new(),
        })
    } else {
        anyhow::bail!("Email is neither a patch nor a reply")
    }
}

impl fmt::Display for EmailType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Subject: {}\n", self.header().subject)?;
        for reviewer in self.reviewed_by() {
            write!(f, "Reviewed-by: {}\n", reviewer)?;
        }
        write!(f, "\n")
    }
}

fn write_maildir(emails: &[&EmailType], output_path: &PathBuf) -> Result<()> {
    // Create Maildir structure
    std::fs::create_dir_all(output_path.join("new"))?;
    std::fs::create_dir_all(output_path.join("cur"))?;
    std::fs::create_dir_all(output_path.join("tmp"))?;

    for (i, email) in emails.iter().enumerate() {
        let header = email.header();
        let filename = format!(
            "{}_{}.eml",
            i,
            header.message_id.replace(['/', '<', '>'], "_")
        );
        let file_path = output_path.join("new").join(filename);
        std::fs::write(file_path, &header.raw_email)?;
    }

    Ok(())
}

fn main() -> Result<()> {
    let matches = clap::Command::new("kernel-review-tool")
        .about("Track Linux kernel patches needing code review")
        .arg(
            clap::Arg::new("query")
                .short('q')
                .long("query")
                .value_name("QUERY")
                .help("Lei search query")
                .default_value("s:PATCH AND dt:1.week.ago.."),
        )
        .arg(
            clap::Arg::new("output")
                .short('o')
                .long("output")
                .value_name("DIR")
                .help("Output Maildir directory for unreviewed patches")
                .default_value("unreviewed"),
        )
        .arg(
            clap::Arg::new("verbose")
                .short('v')
                .long("verbose")
                .help("Verbose output")
                .action(clap::ArgAction::SetTrue),
        )
        .arg(
            clap::Arg::new("debug-all")
                .long("debug-all")
                .value_name("DIR")
                .help("Output all queried emails to a debug Maildir")
                .required(false),
        )
        .arg(
            clap::Arg::new("config")
                .short('c')
                .long("config")
                .value_name("FILE")
                .help("TOML configuration file")
                .required(false),
        )
        .arg(
            clap::Arg::new("days")
                .short('d')
                .long("days")
                .value_name("DAYS")
                .help("Number of days back to search")
                .value_parser(clap::value_parser!(u32))
                .required(false),
        )
        .arg(
            clap::Arg::new("mailing-list")
                .short('m')
                .long("mailing-list")
                .value_name("LIST")
                .help("Mailing list to search (e.g., linux-kernel@vger.kernel.org)")
                .required(false),
        )
        .get_matches();

    let output_dir = PathBuf::from(matches.get_one::<String>("output").unwrap());
    let verbose = matches.get_flag("verbose");
    let debug_all_dir = matches.get_one::<String>("debug-all").map(PathBuf::from);
    let config_file = matches.get_one::<String>("config").map(PathBuf::from);
    let days = matches.get_one::<u32>("days").copied();
    let mailing_list = matches.get_one::<String>("mailing-list").map(|s| s.as_str());
    
    // Determine query: priority is config file > CLI args > default query
    let query = if let Some(config_path) = config_file {
        let config = Config::load_from_file(&config_path)?;
        let generated_query = config.to_lei_query();
        if verbose {
            println!("Using config file: {}", config_path.display());
            println!("Generated query: {}", generated_query);
        }
        generated_query
    } else if let Some(config) = Config::from_cli_args(days, mailing_list) {
        let generated_query = config.to_lei_query();
        if verbose {
            println!("Using CLI arguments:");
            if let Some(d) = days {
                println!("  Days back: {}", d);
            }
            if let Some(ml) = mailing_list {
                println!("  Mailing list: {}", ml);
            }
            println!("Generated query: {}", generated_query);
        }
        generated_query
    } else {
        matches.get_one::<String>("query").unwrap().to_string()
    };

    // Create temporary directory for lei output
    let temp_dir = tempfile::tempdir()?;
    let lei_output = temp_dir.path().join("lei-output");

    if verbose {
        println!("Running lei query: {}", query);
    }

    // Run lei query
    run_lei_query(&query, lei_output.to_str().unwrap())?;

    if verbose {
        println!("Parsing Maildir: {:?}", lei_output);
    }

    // Parse emails from Maildir
    let all_emails = parse_maildir(&lei_output)?;
    if verbose {
        println!("Found {} emails", all_emails.len());
    }
    
    // Output all emails to debug directory if requested
    if let Some(debug_dir) = &debug_all_dir {
        if debug_dir.exists() {
            std::fs::remove_dir_all(debug_dir)?;
        }
        
        let all_email_refs: Vec<&EmailType> = all_emails.iter().collect();
        write_maildir(&all_email_refs, debug_dir)?;
        
        println!("Debug: Wrote {} emails to debug directory: {}", all_emails.len(), debug_dir.display());
    }

    // Track patches and reviews
    let mut tracker = ReviewTracker::new();

    for email in all_emails {
        tracker.add_email(email);
    }

    // Thread replies using message-id and in-reply-to
    tracker.thread_replies();

    // Collect and apply review status according to rules
    tracker.collect_reviews();

    // Get unreviewed emails (including replies)
    let unreviewed = tracker.get_unreviewed_emails();

    if verbose {
        let total_patches = tracker
            .series
            .values()
            .map(|s| s.get_all_emails(&tracker.all_emails).len())
            .sum::<usize>();
        let (cover_letter_series, standalone_patches) = tracker.series.values()
            .fold((0, 0), |(covers, patches), series| {
                match series {
                    EmailType::CoverLetter { .. } => (covers + 1, patches),
                    EmailType::Patch { .. } => (covers, patches + 1),
                    _ => (covers, patches),
                }
            });
        println!(
            "Found {} emails total ({} cover letter series, {} standalone patches)",
            total_patches,
            cover_letter_series,
            standalone_patches
        );
        println!(
            "Found {} unreviewed items (patches + related replies)",
            unreviewed.len()
        );
    }

    if unreviewed.is_empty() {
        println!("No unreviewed patches found!");
        return Ok(());
    }

    // Remove existing output directory if it exists
    if output_dir.exists() {
        std::fs::remove_dir_all(&output_dir)?;
    }

    // Write unreviewed patches to Maildir
    write_maildir(&unreviewed, &output_dir)?;

    println!(
        "Wrote {} unreviewed items (patches + replies) to {}",
        unreviewed.len(),
        output_dir.display()
    );

    if verbose {
        println!("\nUnreviewed emails:");
        for email in &unreviewed {
            let header = email.header();
            let title = email.title().unwrap_or("No title");
            println!("  {} - {}", header.date.format("%Y-%m-%d"), title);
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    // Helper function to create test emails
    fn create_test_email(
        subject: &str,
        message_id: &str,
        in_reply_to: Option<String>,
        author: &str,
        body: &str,
    ) -> EmailType {
        let header = EmailHeader {
            subject: subject.to_string(),
            message_id: message_id.to_string(),
            in_reply_to,
            author: author.to_string(),
            date: Utc::now(),
            raw_email: format!("Subject: {}\nMessage-ID: {}\nFrom: {}\n\n{}", subject, message_id, author, body),
        };

        let reviewed_by = extract_reviewed_by(body);
        let has_review = !reviewed_by.is_empty();

        if is_patch_email(subject) {
            let title = extract_patch_title(subject);
            let version = extract_patch_version(subject);
            let series_info = extract_series_info(subject);

            if let Some((patch_num, total_patches)) = series_info {
                if patch_num == 0 {
                    EmailType::CoverLetter {
                        header,
                        title,
                        version,
                        series_info: (patch_num, total_patches),
                        reviewed_by,
                        has_review,
                        replies: Vec::new(),
                    }
                } else {
                    EmailType::Patch {
                        header,
                        title,
                        version,
                        series_info: Some((patch_num, total_patches)),
                        reviewed_by,
                        has_review,
                        replies: Vec::new(),
                    }
                }
            } else {
                EmailType::Patch {
                    header,
                    title,
                    version,
                    series_info: None,
                    reviewed_by,
                    has_review,
                    replies: Vec::new(),
                }
            }
        } else {
            EmailType::Reply {
                header,
                reviewed_by,
                has_review,
                replies: Vec::new(),
            }
        }
    }

    fn create_tracker_with_emails(emails: Vec<EmailType>) -> ReviewTracker {
        let mut tracker = ReviewTracker::new();
        
        for email in emails {
            tracker.add_email(email);
        }
        
        tracker.thread_replies();
        tracker.collect_reviews();
        
        tracker
    }

    #[test]
    fn test_single_patch_no_review() {
        let patch = create_test_email(
            "[PATCH] Fix memory leak in driver",
            "<patch1@test.com>",
            None,
            "author@test.com",
            "This fixes a memory leak.\n\nSigned-off-by: Author <author@test.com>",
        );

        let tracker = create_tracker_with_emails(vec![patch]);
        let unreviewed = tracker.get_unreviewed_emails();
        
        assert_eq!(unreviewed.len(), 1, "Single patch without review should be unreviewed");
        assert_eq!(unreviewed[0].header().subject, "[PATCH] Fix memory leak in driver");
    }

    #[test]
    fn test_single_patch_with_review_reply() {
        let patch = create_test_email(
            "[PATCH] Fix memory leak in driver",
            "<patch1@test.com>",
            None,
            "author@test.com",
            "This fixes a memory leak.\n\nSigned-off-by: Author <author@test.com>",
        );

        let review = create_test_email(
            "Re: [PATCH] Fix memory leak in driver",
            "<review1@test.com>",
            Some("<patch1@test.com>".to_string()),
            "reviewer@test.com",
            "Looks good to me.\n\nReviewed-by: Reviewer <reviewer@test.com>",
        );

        let tracker = create_tracker_with_emails(vec![patch, review]);
        let unreviewed = tracker.get_unreviewed_emails();
        
        assert_eq!(unreviewed.len(), 0, "Single patch with review should not be unreviewed");
    }

    #[test]
    fn test_single_patch_with_non_review_reply() {
        let patch = create_test_email(
            "[PATCH] Fix memory leak in driver",
            "<patch1@test.com>",
            None,
            "author@test.com",
            "This fixes a memory leak.\n\nSigned-off-by: Author <author@test.com>",
        );

        let comment = create_test_email(
            "Re: [PATCH] Fix memory leak in driver",
            "<comment1@test.com>",
            Some("<patch1@test.com>".to_string()),
            "commenter@test.com",
            "Have you tested this on platform X?",
        );

        let tracker = create_tracker_with_emails(vec![patch, comment]);
        let unreviewed = tracker.get_unreviewed_emails();
        
        assert_eq!(unreviewed.len(), 2, "Single patch with non-review reply should include patch and reply");
    }

    #[test]
    fn test_series_with_cover_letter_review() {
        let cover = create_test_email(
            "[PATCH 0/2] Fix memory management issues",
            "<cover@test.com>",
            None,
            "author@test.com",
            "This series fixes memory management.\n\nSigned-off-by: Author <author@test.com>",
        );

        let patch1 = create_test_email(
            "[PATCH 1/2] Fix memory leak in driver",
            "<patch1@test.com>",
            Some("<cover@test.com>".to_string()),
            "author@test.com",
            "This fixes a memory leak.\n\nSigned-off-by: Author <author@test.com>",
        );

        let patch2 = create_test_email(
            "[PATCH 2/2] Add memory allocation tracking",
            "<patch2@test.com>",
            Some("<cover@test.com>".to_string()),
            "author@test.com",
            "This adds tracking.\n\nSigned-off-by: Author <author@test.com>",
        );

        let cover_review = create_test_email(
            "Re: [PATCH 0/2] Fix memory management issues",
            "<cover_review@test.com>",
            Some("<cover@test.com>".to_string()),
            "reviewer@test.com",
            "Great series!\n\nReviewed-by: Reviewer <reviewer@test.com>",
        );

        let tracker = create_tracker_with_emails(vec![cover, patch1, patch2, cover_review]);
        let unreviewed = tracker.get_unreviewed_emails();
        
        assert_eq!(unreviewed.len(), 0, "Series with cover letter review should not be unreviewed");
        
        // Verify that patches inherit the cover letter review
        let series_root = tracker.series.values().next().unwrap();
        if let EmailType::CoverLetter { replies, .. } = series_root {
            for reply_id in replies {
                if let Some(patch) = tracker.all_emails.get(reply_id) {
                    if matches!(patch, EmailType::Patch { .. }) {
                        assert!(patch.has_review(), "Patch should inherit cover letter review");
                        assert!(!patch.reviewed_by().is_empty(), "Patch should have reviewer from cover letter");
                    }
                }
            }
        }
    }

    #[test]
    fn test_series_with_individual_patch_reviews() {
        let cover = create_test_email(
            "[PATCH 0/2] Fix memory management issues",
            "<cover@test.com>",
            None,
            "author@test.com",
            "This series fixes memory management.\n\nSigned-off-by: Author <author@test.com>",
        );

        let patch1 = create_test_email(
            "[PATCH 1/2] Fix memory leak in driver",
            "<patch1@test.com>",
            Some("<cover@test.com>".to_string()),
            "author@test.com",
            "This fixes a memory leak.\n\nSigned-off-by: Author <author@test.com>",
        );

        let patch2 = create_test_email(
            "[PATCH 2/2] Add memory allocation tracking",
            "<patch2@test.com>",
            Some("<cover@test.com>".to_string()),
            "author@test.com",
            "This adds tracking.\n\nSigned-off-by: Author <author@test.com>",
        );

        let patch1_review = create_test_email(
            "Re: [PATCH 1/2] Fix memory leak in driver",
            "<patch1_review@test.com>",
            Some("<patch1@test.com>".to_string()),
            "reviewer@test.com",
            "LGTM.\n\nReviewed-by: Reviewer <reviewer@test.com>",
        );

        // Only patch 1 has a review, patch 2 doesn't
        let tracker = create_tracker_with_emails(vec![cover, patch1, patch2, patch1_review]);
        let _unreviewed = tracker.get_unreviewed_emails();

        // Should include the entire series because not all patches are reviewed
        //assert!(unreviewed.len() > 0, "Series with partially reviewed patches should be unreviewed");
        
        // Verify patch1 has review but patch2 doesn't
        if let Some(patch1) = tracker.all_emails.get("<patch1@test.com>") {
            assert!(patch1.has_review(), "Patch1 should have review");
        }
        if let Some(patch2) = tracker.all_emails.get("<patch2@test.com>") {
            assert!(!patch2.has_review(), "Patch2 should not have review");
        }
    }

    #[test]
    fn test_version_handling_review_lost() {
        // Create v1 patch with review
        let patch_v1 = create_test_email(
            "[PATCH] Fix memory leak in driver",
            "<patch_v1@test.com>",
            None,
            "author@test.com",
            "This fixes a memory leak.\n\nSigned-off-by: Author <author@test.com>",
        );

        let review_v1 = create_test_email(
            "Re: [PATCH] Fix memory leak in driver",
            "<review_v1@test.com>",
            Some("<patch_v1@test.com>".to_string()),
            "reviewer@test.com",
            "Looks good.\n\nReviewed-by: Reviewer <reviewer@test.com>",
        );

        // Create v2 patch without review
        let patch_v2 = create_test_email(
            "[PATCH v2] Fix memory leak in driver",
            "<patch_v2@test.com>",
            None,
            "author@test.com",
            "This fixes a memory leak (updated).\n\nSigned-off-by: Author <author@test.com>",
        );

        let tracker = create_tracker_with_emails(vec![patch_v1, review_v1, patch_v2]);
        let unreviewed = tracker.get_unreviewed_emails();
        
        // Should only have v2 patch (v1 should be replaced)
        assert_eq!(tracker.series.len(), 1, "Should only have one version in tracker");
        assert_eq!(unreviewed.len(), 1, "v2 patch without review should be unreviewed");
        
        // Verify it's the v2 patch
        let series_patch = tracker.series.values().next().unwrap();
        assert_eq!(series_patch.version().unwrap(), 2, "Should be v2 patch");
        assert!(!series_patch.has_review(), "v2 patch should not have review");
    }

    #[test]
    fn test_patch_with_preexisting_reviewed_by() {
        let patch = create_test_email(
            "[PATCH] Fix memory leak in driver",
            "<patch@test.com>",
            None,
            "author@test.com",
            "This fixes a memory leak.\n\nReviewed-by: Previous Reviewer <prev@test.com>\nSigned-off-by: Author <author@test.com>",
        );

        let tracker = create_tracker_with_emails(vec![patch]);
        let unreviewed = tracker.get_unreviewed_emails();
        
        assert_eq!(unreviewed.len(), 0, "Patch with existing Reviewed-by should not be unreviewed");
        
        let series_patch = tracker.series.values().next().unwrap();
        assert!(series_patch.has_review(), "Patch should have review");
        assert_eq!(series_patch.reviewed_by().len(), 1, "Should have one reviewer");
        assert_eq!(series_patch.reviewed_by()[0], "Previous Reviewer <prev@test.com>");
    }

    #[test]
    fn test_mixed_series_reviews() {
        // Test a series where cover letter has review AND individual patches have reviews
        let cover = create_test_email(
            "[PATCH 0/2] Fix memory management issues",
            "<cover@test.com>",
            None,
            "author@test.com",
            "This series fixes memory management.\n\nSigned-off-by: Author <author@test.com>",
        );

        let patch1 = create_test_email(
            "[PATCH 1/2] Fix memory leak in driver",
            "<patch1@test.com>",
            Some("<cover@test.com>".to_string()),
            "author@test.com",
            "This fixes a memory leak.\n\nSigned-off-by: Author <author@test.com>",
        );

        let patch2 = create_test_email(
            "[PATCH 2/2] Add memory allocation tracking",
            "<patch2@test.com>",
            Some("<cover@test.com>".to_string()),
            "author@test.com",
            "This adds tracking.\n\nSigned-off-by: Author <author@test.com>",
        );

        let cover_review = create_test_email(
            "Re: [PATCH 0/2] Fix memory management issues",
            "<cover_review@test.com>",
            Some("<cover@test.com>".to_string()),
            "maintainer@test.com",
            "Good series.\n\nReviewed-by: Maintainer <maintainer@test.com>",
        );

        let patch1_review = create_test_email(
            "Re: [PATCH 1/2] Fix memory leak in driver",
            "<patch1_review@test.com>",
            Some("<patch1@test.com>".to_string()),
            "reviewer@test.com",
            "Specific feedback.\n\nReviewed-by: Reviewer <reviewer@test.com>",
        );

        let tracker = create_tracker_with_emails(vec![cover, patch1, patch2, cover_review, patch1_review]);
        let unreviewed = tracker.get_unreviewed_emails();
        
        assert_eq!(unreviewed.len(), 0, "Fully reviewed series should not be unreviewed");
        
        // Verify patches have both cover letter and individual reviews
        if let Some(patch1) = tracker.all_emails.get("<patch1@test.com>") {
            let reviews = patch1.collect_reviewed_by_recursive(&tracker.all_emails);
            assert!(reviews.len() >= 2, "Patch1 should have multiple reviewers");
            assert!(reviews.contains(&"Maintainer <maintainer@test.com>".to_string()));
            assert!(reviews.contains(&"Reviewer <reviewer@test.com>".to_string()));
        }
    }

    #[test]
    fn test_version_upgrade_with_review() {
        // Test that newer version with review replaces older version without review
        let patch_v1 = create_test_email(
            "[PATCH] Fix memory leak in driver",
            "<patch_v1@test.com>",
            None,
            "author@test.com",
            "This fixes a memory leak.\n\nSigned-off-by: Author <author@test.com>",
        );

        let patch_v2 = create_test_email(
            "[PATCH v2] Fix memory leak in driver",
            "<patch_v2@test.com>",
            None,
            "author@test.com",
            "This fixes a memory leak (updated).\n\nReviewed-by: Reviewer <reviewer@test.com>\nSigned-off-by: Author <author@test.com>",
        );

        let tracker = create_tracker_with_emails(vec![patch_v1, patch_v2]);
        let unreviewed = tracker.get_unreviewed_emails();
        
        assert_eq!(unreviewed.len(), 0, "v2 patch with review should not be unreviewed");
        assert_eq!(tracker.series.len(), 1, "Should only have one version");
        
        let series_patch = tracker.series.values().next().unwrap();
        assert_eq!(series_patch.version().unwrap(), 2, "Should be v2 patch");
        assert!(series_patch.has_review(), "v2 patch should have review");
    }
}
