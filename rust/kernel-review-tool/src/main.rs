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
        replies: HashMap<String, EmailType>, // message_id -> reply
    },
    Patch {
        header: EmailHeader,
        title: String,
        version: u32,
        series_info: Option<(u32, u32)>, // (patch_num, total_patches) or None for standalone
        reviewed_by: Vec<String>,
        has_review: bool,
        replies: HashMap<String, EmailType>, // message_id -> reply
    },
    Reply {
        header: EmailHeader,
        reviewed_by: Vec<String>,
        has_review: bool,
        replies: HashMap<String, EmailType>, // message_id -> reply
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

    fn add_reply(&mut self, reply: EmailType) {
        println!(
            "Attach reply to message! {} {} {} {}",
            self.header().subject,
            self.header().message_id,
            reply.header().subject,
            reply.header().message_id
        );
        let reply_id = reply.header().message_id.clone();
        match self {
            EmailType::CoverLetter { replies, .. } => {
                replies.insert(reply_id, reply);
            }
            EmailType::Patch { replies, .. } => {
                replies.insert(reply_id, reply);
            }
            EmailType::Reply { replies, .. } => {
                replies.insert(reply_id, reply);
            }
        }
    }

    fn get_all_emails(&self) -> Vec<&EmailType> {
        let mut result = vec![self];
        let replies = match self {
            EmailType::CoverLetter { replies, .. } => replies,
            EmailType::Patch { replies, .. } => replies,
            EmailType::Reply { replies, .. } => replies,
        };

        for reply in replies.values() {
            result.extend(reply.get_all_emails());
        }
        result
    }

    fn collect_reviewed_by_recursive(&self) -> Vec<String> {
        let mut all_reviews = self.reviewed_by().clone();
        let replies = match self {
            EmailType::CoverLetter { replies, .. } => replies,
            EmailType::Patch { replies, .. } => replies,
            EmailType::Reply { replies, .. } => replies,
        };

        for reply in replies.values() {
            all_reviews.extend(reply.collect_reviewed_by_recursive());
        }
        all_reviews
    }

    fn display_thread(&self, indent: usize) -> String {
        let mut result = String::new();
        let indent_str = "  ".repeat(indent);

        // Display this email
        let email_type = match self {
            EmailType::CoverLetter { .. } => "COVER",
            EmailType::Patch { .. } => "PATCH",
            EmailType::Reply { .. } => "REPLY",
        };

        result.push_str(&format!(
            "{}[{}] {}\n",
            indent_str,
            email_type,
            self.header().subject
        ));
        result.push_str(&format!(
            "{}    Author: {}\n",
            indent_str,
            self.header().author
        ));
        result.push_str(&format!(
            "{}    Message-ID: {}\n",
            indent_str,
            self.header().message_id
        ));
        result.push_str(&format!(
            "{}    Date: {}\n",
            indent_str,
            self.header().date.format("%Y-%m-%d %H:%M")
        ));

        if !self.reviewed_by().is_empty() {
            result.push_str(&format!(
                "{}    Reviewed-by: {}\n",
                indent_str,
                self.reviewed_by().join(", ")
            ));
        }

        // Display replies
        let replies = match self {
            EmailType::CoverLetter { replies, .. } => replies,
            EmailType::Patch { replies, .. } => replies,
            EmailType::Reply { replies, .. } => replies,
        };

        if !replies.is_empty() {
            for reply in replies.values() {
                result.push_str(&reply.display_thread(indent + 1));
            }
        }

        result
    }

    fn display_series(&self) -> String {
        match self {
            EmailType::CoverLetter { title, version, .. } => {
                let mut result = String::new();

                result.push_str(&format!("=== SERIES: {} v{} ===\n", title, version));
                result.push_str(&format!(
                    "Status: {}\n",
                    if self.is_series_reviewed() {
                        "REVIEWED"
                    } else {
                        "NEEDS REVIEW"
                    }
                ));

                // Display cover letter
                result.push_str("COVER LETTER:\n");
                result.push_str(&self.display_thread(0));
                result.push_str("\n");

                result.push_str("=== END SERIES ===\n\n");
                result
            }
            _ => "Not a cover letter - cannot display as series\n".to_string(),
        }
    }

    fn is_series_reviewed(&self) -> bool {
        match self {
            EmailType::CoverLetter { replies, .. } => {
                // Check if all patches in the series (direct replies that are patches) have reviews
                let patches: Vec<_> = replies
                    .values()
                    .filter(|email| matches!(email, EmailType::Patch { .. }))
                    .collect();

                if patches.is_empty() {
                    return false;
                }

                // All patches must have reviews (either directly or from cover letter)
                patches
                    .iter()
                    .all(|patch| !patch.collect_reviewed_by_recursive().is_empty())
            }
            _ => false,
        }
    }

    fn get_series_patches(&self) -> Vec<&EmailType> {
        match self {
            EmailType::CoverLetter { replies, .. } => {
                let mut patches: Vec<_> = replies
                    .values()
                    .filter(|email| matches!(email, EmailType::Patch { .. }))
                    .collect();

                // Sort patches by their patch number
                patches.sort_by_key(|patch| {
                    if let EmailType::Patch {
                        series_info: Some((patch_num, _)),
                        ..
                    } = patch
                    {
                        *patch_num
                    } else {
                        0
                    }
                });

                patches
            }
            _ => Vec::new(),
        }
    }
}

#[derive(Debug)]
struct ReviewTracker {
    cover_letters: HashMap<String, EmailType>, // message_id -> cover letter
    standalone_patches: HashMap<String, EmailType>, // message_id -> patch
    all_emails: HashMap<String, EmailType>,    // message_id -> email (for reply threading)
}

impl ReviewTracker {
    fn new() -> Self {
        Self {
            cover_letters: HashMap::new(),
            standalone_patches: HashMap::new(),
            all_emails: HashMap::new(),
        }
    }

    fn add_email(&mut self, email: EmailType) {
        let message_id = email.header().message_id.clone();

        // Store all emails for reply threading
        self.all_emails.insert(message_id.clone(), email.clone());

        match &email {
            EmailType::CoverLetter { title, version, .. } => {
                // Check for existing cover letters with same title and handle versions
                let mut to_remove = Vec::new();
                for (existing_id, existing_cover) in &self.cover_letters {
                    if let Some(existing_title) = existing_cover.title() {
                        if existing_title == title {
                            if let Some(existing_version) = existing_cover.version() {
                                if *version > existing_version {
                                    // Remove older version
                                    to_remove.push(existing_id.clone());
                                } else if *version < existing_version {
                                    // Ignore older version
                                    return;
                                }
                            }
                        }
                    }
                }

                for id in to_remove {
                    self.cover_letters.remove(&id);
                }

                self.cover_letters.insert(message_id, email);
            }
            EmailType::Patch {
                title,
                version,
                series_info: None,
                header,
                ..
            } => {
                // Standalone patch - handle version updates
                let message_id = header.message_id.clone();

                // Check for existing standalone patches with same title
                let mut to_remove = Vec::new();
                for (existing_id, existing_patch) in &self.standalone_patches {
                    if let Some(existing_title) = existing_patch.title() {
                        if existing_title == title {
                            if let Some(existing_version) = existing_patch.version() {
                                if *version > existing_version {
                                    // Remove older version
                                    to_remove.push(existing_id.clone());
                                } else if *version < existing_version {
                                    // Ignore older patch
                                    return;
                                } else {
                                    // Same version, merge reviews
                                    to_remove.push(existing_id.clone());
                                    break;
                                }
                            }
                        }
                    }
                }

                for id in to_remove {
                    self.standalone_patches.remove(&id);
                }

                self.standalone_patches.insert(message_id, email);
            }
            EmailType::Patch {
                series_info: Some(_),
                ..
            } => {
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
            if let Some(reply_email) = self.all_emails.remove(&reply_id) {
                self.attach_reply_to_parent(reply_email, &parent_id);
            }
        }
    }

    fn attach_reply_to_parent(&mut self, reply: EmailType, parent_id: &str) {
        // Try to find parent in cover letters
        for cover in self.cover_letters.values_mut() {
            if cover.header().message_id == parent_id {
                cover.add_reply(reply);
                return;
            }
            if Self::attach_reply_recursive(cover, &reply, parent_id) {
                return;
            }
        }

        // Try to find parent in standalone patches
        for patch in self.standalone_patches.values_mut() {
            if patch.header().message_id == parent_id {
                patch.add_reply(reply);
                return;
            }
            if Self::attach_reply_recursive(patch, &reply, parent_id) {
                return;
            }
        }

        // If parent not found, store as orphaned (could be handled differently)
    }

    fn attach_reply_recursive(email: &mut EmailType, reply: &EmailType, parent_id: &str) -> bool {
        let replies = match email {
            EmailType::CoverLetter { replies, .. } => replies,
            EmailType::Patch { replies, .. } => replies,
            EmailType::Reply { replies, .. } => replies,
        };

        for child in replies.values_mut() {
            if child.header().message_id == parent_id {
                child.add_reply(reply.clone());
                return true;
            }
            if Self::attach_reply_recursive(child, reply, parent_id) {
                return true;
            }
        }
        false
    }

    fn collect_reviews(&mut self) {
        // Apply review rules after all threading is complete
        let cover_keys: Vec<_> = self.cover_letters.keys().cloned().collect();
        for key in cover_keys {
            if let Some(cover) = self.cover_letters.get_mut(&key) {
                Self::apply_series_review_rules(cover);
            }
        }

        let patch_keys: Vec<_> = self.standalone_patches.keys().cloned().collect();
        for key in patch_keys {
            if let Some(patch) = self.standalone_patches.get_mut(&key) {
                Self::apply_patch_review_rules(patch);
            }
        }
    }

    fn apply_series_review_rules(cover_letter: &mut EmailType) {
        // Get cover letter reviews first (before any mutable borrows)
        let cover_reviews = cover_letter.collect_reviewed_by_recursive();

        if let EmailType::CoverLetter { replies, .. } = cover_letter {
            // Apply cover letter reviews to all patches in the series
            if !cover_reviews.is_empty() {
                for email in replies.values_mut() {
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

            // Apply individual patch reviews
            for email in replies.values_mut() {
                Self::apply_patch_review_rules(email);
            }
        }
    }

    fn apply_patch_review_rules(patch: &mut EmailType) {
        println!(
            "Applying patch review rules to \n{}",
            patch.display_thread(2)
        );
        let reviews = patch.collect_reviewed_by_recursive();
        match patch {
            EmailType::Patch { has_review, .. } => {
                *has_review = !reviews.is_empty();
            }
            _ => {}
        }
    }

    fn get_unreviewed_emails(&self) -> Vec<&EmailType> {
        let mut result = Vec::new();

        // Add unreviewed series (cover letters with unreviewed patches)
        for cover in self.cover_letters.values() {
            if !cover.is_series_reviewed() {
                result.extend(cover.get_all_emails());
            }
        }

        // Add unreviewed standalone patches
        for patch in self.standalone_patches.values() {
            if !patch.has_review() {
                result.extend(patch.get_all_emails());
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
    cmd.args(&["q", "-o", output_dir, query]);
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

    println!(
        "parsed email {} {} {:?} {}",
        &header.subject, &header.message_id, &header.in_reply_to, &header.author
    );

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
                    replies: HashMap::new(),
                })
            } else {
                Ok(EmailType::Patch {
                    header,
                    title,
                    version,
                    series_info: Some((patch_num, total_patches)),
                    reviewed_by,
                    has_review,
                    replies: HashMap::new(),
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
                replies: HashMap::new(),
            })
        }
    } else if is_reply_email(&subject) {
        // Reply email
        Ok(EmailType::Reply {
            header,
            reviewed_by,
            has_review,
            replies: HashMap::new(),
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
        .get_matches();

    let query = matches.get_one::<String>("query").unwrap();
    let output_dir = PathBuf::from(matches.get_one::<String>("output").unwrap());
    let verbose = matches.get_flag("verbose");

    // Create temporary directory for lei output
    let temp_dir = tempfile::tempdir()?;
    let lei_output = temp_dir.path().join("lei-output");

    if verbose {
        println!("Running lei query: {}", query);
    }

    // Run lei query
    run_lei_query(query, lei_output.to_str().unwrap())?;

    if verbose {
        println!("Parsing Maildir: {:?}", lei_output);
    }

    // Parse emails from Maildir
    let all_emails = parse_maildir(&lei_output)?;
    if verbose {
        println!("Found {} emails", all_emails.len());
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
            .cover_letters
            .values()
            .map(|s| s.get_all_emails().len())
            .sum::<usize>()
            + tracker.standalone_patches.len();
        println!(
            "Found {} emails total ({} series, {} standalone)",
            total_patches,
            tracker.cover_letters.len(),
            tracker.standalone_patches.len()
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
