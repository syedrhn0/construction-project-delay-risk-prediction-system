CREATE DATABASE construction_risk;
USE construction_risk;

-- verifying count of loaded data
select count(*) from projects;
select count(*) from issues_ncr_rfi;
select count(*) from task_dependencies;
select count(*) from task_progress_updates;
select count(*) from tasks;
select count(*) from weather_log;


CREATE TABLE DimProjects (
    -- Basic identification
    project_id INT PRIMARY KEY,
    project_name VARCHAR(200),
    project_type VARCHAR(50),
    client_type VARCHAR(50),
    state VARCHAR(100),
    city VARCHAR(100),
    
    -- Project parties
    contractor_name VARCHAR(200),
    consultant_name VARCHAR(200),
    
    -- Important dates
    start_date DATE,
    planned_end_date DATE,
    revised_end_date DATE,
    
    -- Project details
    contract_duration_days INT,
    project_value_cr DECIMAL(10,2),
    current_project_status VARCHAR(50),
    
    -- Calculated fields (we'll compute these)
    actual_delay_days INT,           -- How many days delayed
    actual_duration_days INT,        -- How long project actually took
    delay_percentage DECIMAL(10,2)   -- Delay as percentage of total time
);

-- Now fill the table with data
INSERT INTO DimProjects
SELECT 
    -- Copy all basic columns as-is
    project_id,
    project_name,
    project_type,
    client_type,
    state,
    city,
    contractor_name,
    consultant_name,
    start_date,
    planned_end_date,
    revised_end_date,
    contract_duration_days,
    project_value_cr,
    current_project_status,
    
    -- Calculate: How many days was the project delayed?
    -- Formula: Revised end date - Planned end date
    DATEDIFF(revised_end_date, planned_end_date) AS actual_delay_days,
    
    -- Calculate: Total project duration
    -- Formula: Revised end date - Start date
    DATEDIFF(revised_end_date, start_date) AS actual_duration_days,
    
    -- Calculate: Delay as percentage
    -- Formula: (Delay days / Contract duration) × 100
    ROUND(100.0 * DATEDIFF(revised_end_date, planned_end_date) / contract_duration_days, 2) AS delay_percentage
    
FROM projects;  -- Source: Your imported projects table

-- Check what we created
SELECT COUNT(*) AS total_projects FROM DimProjects;
-- Should show: 28 projects

-- ----------------------------------------------------------------------------
-- Table 2: DimTasks - Master list of all tasks
-- ----------------------------------------------------------------------------
-- What we're doing: Creating a clean task master table

CREATE TABLE DimTasks (
    task_id INT PRIMARY KEY,
    project_id INT,
    wbs_level INT,
    task_name VARCHAR(200),
    task_category VARCHAR(100),
    planned_start_date DATE,
    planned_end_date DATE,
    planned_duration_days INT,
    task_weight_pct DECIMAL(10,2),
    critical_flag CHAR(1),              -- 'Y' = critical path task
    baseline_sequence_no INT,
    
    -- Add indexes to make queries faster
    INDEX idx_project (project_id),
    INDEX idx_critical (critical_flag)
);

-- Fill with task data (no calculations needed - just copy)
INSERT INTO DimTasks
SELECT * FROM tasks;  -- Source: Your imported tasks table

-- Check what we created
SELECT COUNT(*) AS total_tasks FROM DimTasks;
-- Should show: 5,746 tasks

-- ----------------------------------------------------------------------------
-- Table 3: DimDelayReasons - Lookup table for delay reasons
-- ----------------------------------------------------------------------------
-- What we're doing: Creating a small reference table of all delay types

CREATE TABLE DimDelayReasons (
    reason_id INT AUTO_INCREMENT PRIMARY KEY,
    reason_code VARCHAR(100),
    reason_description VARCHAR(200),
    reason_category VARCHAR(50),        -- Group similar reasons together
    INDEX idx_code (reason_code)
);

-- Fill with unique delay reasons from progress updates
INSERT INTO DimDelayReasons (reason_code, reason_description, reason_category)
SELECT DISTINCT 
    delay_reason_code AS reason_code,
    delay_reason_code AS reason_description,
    
    -- Categorize each delay reason
    CASE 
        WHEN delay_reason_code = 'Material Delay' THEN 'Supply Chain'
        WHEN delay_reason_code = 'Labour Shortage' THEN 'Resource'
        WHEN delay_reason_code = 'Weather Impact' THEN 'External'
        WHEN delay_reason_code = 'Approval Pending' THEN 'Administrative'
        ELSE 'Other'
    END AS reason_category
    
FROM task_progress_updates
WHERE delay_reason_code IS NOT NULL 
  AND delay_reason_code != 'None'
ORDER BY delay_reason_code;

-- Check what we created
SELECT * FROM DimDelayReasons;
-- Should show: 4 main delay reasons


-- ============================================================================
-- PART 2: CREATE FACT TABLES (Measurements & Metrics)
-- ============================================================================
-- Fact tables contain numbers/measurements (how much, how many)
-- This is where we calculate our risk scores and KPIs

-- ----------------------------------------------------------------------------
-- THE MAIN TABLE: FactProjectMetrics
-- ----------------------------------------------------------------------------
-- What we're doing: For each project, calculate ALL the metrics we need
-- This includes task counts, delay reasons, issues, weather impact, and RISK SCORE

-- We'll build this step by step using temporary helper tables

-- HELPER TABLE 1: Count tasks per project
CREATE TABLE temp_task_counts AS
SELECT 
    project_id,
    COUNT(*) AS total_tasks,
    SUM(CASE WHEN critical_flag = 'Y' THEN 1 ELSE 0 END) AS critical_tasks
FROM DimTasks
GROUP BY project_id;

SELECT * FROM temp_task_counts LIMIT 5;


-- HELPER TABLE 2: Get latest status for each task
CREATE TABLE temp_latest_task_status AS
SELECT 
    project_id,
    task_id,
    actual_pct_complete,
    planned_pct_complete,
    status_flag
FROM (
    SELECT 
        project_id,
        task_id,
        actual_pct_complete,
        planned_pct_complete,
        status_flag,
        ROW_NUMBER() OVER (PARTITION BY task_id ORDER BY update_date DESC) AS rn
    FROM task_progress_updates
) ranked
WHERE rn = 1;

SELECT * FROM temp_latest_task_status LIMIT 5;


-- HELPER TABLE 3: Summarize task progress per project
CREATE TABLE temp_task_progress AS
SELECT 
    project_id,
    AVG(actual_pct_complete) AS avg_completion,
    AVG(CASE WHEN planned_pct_complete > 0 
        THEN actual_pct_complete / planned_pct_complete 
        ELSE NULL END) AS avg_velocity,
    SUM(CASE WHEN status_flag = 'Blocked' THEN 1 ELSE 0 END) AS blocked_count,
    SUM(CASE WHEN status_flag = 'Completed' THEN 1 ELSE 0 END) AS completed_count,
    SUM(CASE WHEN status_flag = 'In Progress' THEN 1 ELSE 0 END) AS in_progress_count
FROM temp_latest_task_status
GROUP BY project_id;

SELECT * FROM temp_task_progress LIMIT 5;


-- HELPER TABLE 4: Count delay reasons per project
CREATE TABLE temp_delay_counts AS
SELECT 
    project_id,
    SUM(CASE WHEN delay_reason_code = 'Material Delay' THEN 1 ELSE 0 END) AS material_delays,
    SUM(CASE WHEN delay_reason_code = 'Labour Shortage' THEN 1 ELSE 0 END) AS labour_delays,
    SUM(CASE WHEN delay_reason_code = 'Weather Impact' THEN 1 ELSE 0 END) AS weather_delays,
    SUM(CASE WHEN delay_reason_code = 'Approval Pending' THEN 1 ELSE 0 END) AS approval_delays
FROM task_progress_updates
GROUP BY project_id;

SELECT * FROM temp_delay_counts LIMIT 5;


-- HELPER TABLE 5: Count issues per project
CREATE TABLE temp_issue_counts AS
SELECT 
    project_id,
    COUNT(*) AS total_issues,
    SUM(CASE WHEN severity = 'High' THEN 1 ELSE 0 END) AS high_severity_issues,
    SUM(CASE WHEN issue_status = 'Open' THEN 1 ELSE 0 END) AS open_issues,
    AVG(approval_delay_days) AS avg_approval_delay,
    SUM(CASE WHEN issue_type = 'NCR' THEN 1 ELSE 0 END) AS ncr_count,
    SUM(CASE WHEN issue_type = 'RFI' THEN 1 ELSE 0 END) AS rfi_count,
    SUM(CASE WHEN issue_type = 'Safety' THEN 1 ELSE 0 END) AS safety_count
FROM issues_ncr_rfi
GROUP BY project_id;

SELECT * FROM temp_issue_counts LIMIT 5;


-- HELPER TABLE 6: Count weather impact per project
CREATE TABLE temp_weather_counts AS
SELECT 
    project_id,
    SUM(CASE WHEN work_stop_flag = 'Y' THEN 1 ELSE 0 END) AS work_stop_days,
    SUM(CASE WHEN weather_severity = 'Severe' THEN 1 ELSE 0 END) AS severe_weather_days,
    AVG(rainfall_mm) AS avg_rainfall
FROM weather_log
GROUP BY project_id;

SELECT * FROM temp_weather_counts LIMIT 5;


-- HELPER TABLE 7: Count dependencies per project
CREATE TABLE temp_dependency_counts AS
SELECT 
    project_id,
    SUM(CASE WHEN critical_dependency_flag = 'Y' THEN 1 ELSE 0 END) AS critical_dependencies
FROM task_dependencies
GROUP BY project_id;

SELECT * FROM temp_dependency_counts LIMIT 5;


-- ----------------------------------------------------------------------------
-- NOW CREATE THE MAIN TABLE: FactProjectMetrics
-- ----------------------------------------------------------------------------
-- Combine all helper tables and calculate risk scores

CREATE TABLE FactProjectMetrics (
    -- Project identification
    project_id INT PRIMARY KEY,
    project_name VARCHAR(200),
    project_type VARCHAR(50),
    client_type VARCHAR(50),
    state VARCHAR(100),
    city VARCHAR(100),
    contractor_name VARCHAR(200),
    consultant_name VARCHAR(200),
    current_project_status VARCHAR(50),
    
    -- Basic project metrics
    actual_delay_days INT,
    delay_percentage DECIMAL(10,2),
    contract_duration_days INT,
    project_value_cr DECIMAL(10,2),
    
    -- Task metrics
    total_tasks INT,
    critical_tasks_count INT,
    avg_completion_pct DECIMAL(10,2),
    avg_progress_velocity DECIMAL(10,3),
    blocked_tasks_count INT,
    completed_tasks_count INT,
    in_progress_tasks_count INT,
    
    -- Delay reasons
    material_delay_count INT,
    labour_shortage_count INT,
    weather_impact_count INT,
    approval_pending_count INT,
    
    -- Issues
    total_issues INT,
    high_severity_issues INT,
    open_issues INT,
    avg_approval_delay_days DECIMAL(10,2),
    ncr_count INT,
    rfi_count INT,
    safety_count INT,
    
    -- Weather
    work_stop_days INT,
    severe_weather_days INT,
    avg_rainfall DECIMAL(10,2),
    
    -- Dependencies
    critical_dependencies INT,
    
    -- Risk score
    risk_score DECIMAL(10,2),
    risk_category VARCHAR(50),
    
    INDEX idx_status (current_project_status),
    INDEX idx_risk (risk_category)
);

-- Fill FactProjectMetrics by combining all helper tables
INSERT INTO FactProjectMetrics
SELECT 
    -- Basic project info
    p.project_id,
    p.project_name,
    p.project_type,
    p.client_type,
    p.state,
    p.city,
    p.contractor_name,
    p.consultant_name,
    p.current_project_status,
    p.actual_delay_days,
    p.delay_percentage,
    p.contract_duration_days,
    p.project_value_cr,
    
    -- Task metrics
    COALESCE(tc.total_tasks, 0) AS total_tasks,
    COALESCE(tc.critical_tasks, 0) AS critical_tasks_count,
    COALESCE(tp.avg_completion, 0) AS avg_completion_pct,
    COALESCE(tp.avg_velocity, 0) AS avg_progress_velocity,
    COALESCE(tp.blocked_count, 0) AS blocked_tasks_count,
    COALESCE(tp.completed_count, 0) AS completed_tasks_count,
    COALESCE(tp.in_progress_count, 0) AS in_progress_tasks_count,
    
    -- Delay reasons
    COALESCE(dc.material_delays, 0) AS material_delay_count,
    COALESCE(dc.labour_delays, 0) AS labour_shortage_count,
    COALESCE(dc.weather_delays, 0) AS weather_impact_count,
    COALESCE(dc.approval_delays, 0) AS approval_pending_count,
    
    -- Issues
    COALESCE(ic.total_issues, 0) AS total_issues,
    COALESCE(ic.high_severity_issues, 0) AS high_severity_issues,
    COALESCE(ic.open_issues, 0) AS open_issues,
    COALESCE(ic.avg_approval_delay, 0) AS avg_approval_delay_days,
    COALESCE(ic.ncr_count, 0) AS ncr_count,
    COALESCE(ic.rfi_count, 0) AS rfi_count,
    COALESCE(ic.safety_count, 0) AS safety_count,
    
    -- Weather
    COALESCE(wc.work_stop_days, 0) AS work_stop_days,
    COALESCE(wc.severe_weather_days, 0) AS severe_weather_days,
    COALESCE(wc.avg_rainfall, 0) AS avg_rainfall,
    
    -- Dependencies
    COALESCE(depc.critical_dependencies, 0) AS critical_dependencies,
    
    -- ====================================================================
    -- RISK SCORE CALCULATION
    -- ====================================================================
    -- Add up 6 components to get total score (0-100)
    
    ROUND(
        -- Component 1: Schedule Performance (25%)
        (CASE 
            WHEN p.actual_delay_days > 90 THEN 25
            WHEN p.actual_delay_days > 60 THEN 20
            WHEN p.actual_delay_days > 30 THEN 15
            WHEN p.actual_delay_days > 0 THEN 10
            ELSE 0
        END) * 0.25
        
        -- Component 2: Critical Path Risk (20%)
        + (CASE 
            WHEN (COALESCE(tp.blocked_count, 0) * 100.0 / NULLIF(tc.total_tasks, 0)) > 30 THEN 20
            WHEN (COALESCE(tp.blocked_count, 0) * 100.0 / NULLIF(tc.total_tasks, 0)) > 20 THEN 15
            WHEN (COALESCE(tp.blocked_count, 0) * 100.0 / NULLIF(tc.total_tasks, 0)) > 10 THEN 10
            ELSE 5
        END) * 0.20
        
        -- Component 3: Issue Risk (20%)
        + (CASE 
            WHEN COALESCE(ic.open_issues, 0) > 20 THEN 20
            WHEN COALESCE(ic.open_issues, 0) > 10 THEN 15
            WHEN COALESCE(ic.open_issues, 0) > 5 THEN 10
            ELSE 5
        END) * 0.20
        
        -- Component 4: Resource Risk (15%)
        + (CASE 
            WHEN (COALESCE(dc.material_delays, 0) + COALESCE(dc.labour_delays, 0)) > 100 THEN 15
            WHEN (COALESCE(dc.material_delays, 0) + COALESCE(dc.labour_delays, 0)) > 50 THEN 10
            ELSE 5
        END) * 0.15
        
        -- Component 5: External Risk (10%)
        + (CASE 
            WHEN COALESCE(wc.work_stop_days, 0) > 100 THEN 10
            WHEN COALESCE(wc.work_stop_days, 0) > 50 THEN 7
            WHEN COALESCE(wc.work_stop_days, 0) > 20 THEN 5
            ELSE 2
        END) * 0.10
        
        -- Component 6: Progress Velocity Risk (10%)
        + (CASE 
            WHEN COALESCE(tp.avg_velocity, 1) < 0.7 THEN 10
            WHEN COALESCE(tp.avg_velocity, 1) < 0.85 THEN 7
            WHEN COALESCE(tp.avg_velocity, 1) < 1.0 THEN 5
            ELSE 2
        END) * 0.10
    , 2) AS risk_score,
    
    -- Risk category
    CASE 
        WHEN ROUND(
            (CASE WHEN p.actual_delay_days > 90 THEN 25 WHEN p.actual_delay_days > 60 THEN 20 
             WHEN p.actual_delay_days > 30 THEN 15 WHEN p.actual_delay_days > 0 THEN 10 ELSE 0 END) * 0.25
            + (CASE WHEN (COALESCE(tp.blocked_count, 0) * 100.0 / NULLIF(tc.total_tasks, 0)) > 30 THEN 20 
               WHEN (COALESCE(tp.blocked_count, 0) * 100.0 / NULLIF(tc.total_tasks, 0)) > 20 THEN 15 
               WHEN (COALESCE(tp.blocked_count, 0) * 100.0 / NULLIF(tc.total_tasks, 0)) > 10 THEN 10 ELSE 5 END) * 0.20
            + (CASE WHEN COALESCE(ic.open_issues, 0) > 20 THEN 20 WHEN COALESCE(ic.open_issues, 0) > 10 THEN 15 
               WHEN COALESCE(ic.open_issues, 0) > 5 THEN 10 ELSE 5 END) * 0.20
            + (CASE WHEN (COALESCE(dc.material_delays, 0) + COALESCE(dc.labour_delays, 0)) > 100 THEN 15 
               WHEN (COALESCE(dc.material_delays, 0) + COALESCE(dc.labour_delays, 0)) > 50 THEN 10 ELSE 5 END) * 0.15
            + (CASE WHEN COALESCE(wc.work_stop_days, 0) > 100 THEN 10 WHEN COALESCE(wc.work_stop_days, 0) > 50 THEN 7 
               WHEN COALESCE(wc.work_stop_days, 0) > 20 THEN 5 ELSE 2 END) * 0.10
            + (CASE WHEN COALESCE(tp.avg_velocity, 1) < 0.7 THEN 10 WHEN COALESCE(tp.avg_velocity, 1) < 0.85 THEN 7 
               WHEN COALESCE(tp.avg_velocity, 1) < 1.0 THEN 5 ELSE 2 END) * 0.10
        , 2) > 60 THEN 'High Risk'
        WHEN ROUND(
            (CASE WHEN p.actual_delay_days > 90 THEN 25 WHEN p.actual_delay_days > 60 THEN 20 
             WHEN p.actual_delay_days > 30 THEN 15 WHEN p.actual_delay_days > 0 THEN 10 ELSE 0 END) * 0.25
            + (CASE WHEN (COALESCE(tp.blocked_count, 0) * 100.0 / NULLIF(tc.total_tasks, 0)) > 30 THEN 20 
               WHEN (COALESCE(tp.blocked_count, 0) * 100.0 / NULLIF(tc.total_tasks, 0)) > 20 THEN 15 
               WHEN (COALESCE(tp.blocked_count, 0) * 100.0 / NULLIF(tc.total_tasks, 0)) > 10 THEN 10 ELSE 5 END) * 0.20
            + (CASE WHEN COALESCE(ic.open_issues, 0) > 20 THEN 20 WHEN COALESCE(ic.open_issues, 0) > 10 THEN 15 
               WHEN COALESCE(ic.open_issues, 0) > 5 THEN 10 ELSE 5 END) * 0.20
            + (CASE WHEN (COALESCE(dc.material_delays, 0) + COALESCE(dc.labour_delays, 0)) > 100 THEN 15 
               WHEN (COALESCE(dc.material_delays, 0) + COALESCE(dc.labour_delays, 0)) > 50 THEN 10 ELSE 5 END) * 0.15
            + (CASE WHEN COALESCE(wc.work_stop_days, 0) > 100 THEN 10 WHEN COALESCE(wc.work_stop_days, 0) > 50 THEN 7 
               WHEN COALESCE(wc.work_stop_days, 0) > 20 THEN 5 ELSE 2 END) * 0.10
            + (CASE WHEN COALESCE(tp.avg_velocity, 1) < 0.7 THEN 10 WHEN COALESCE(tp.avg_velocity, 1) < 0.85 THEN 7 
               WHEN COALESCE(tp.avg_velocity, 1) < 1.0 THEN 5 ELSE 2 END) * 0.10
        , 2) > 30 THEN 'Medium Risk'
        ELSE 'Low Risk'
    END AS risk_category

FROM DimProjects p
LEFT JOIN temp_task_counts tc ON p.project_id = tc.project_id
LEFT JOIN temp_task_progress tp ON p.project_id = tp.project_id
LEFT JOIN temp_delay_counts dc ON p.project_id = dc.project_id
LEFT JOIN temp_issue_counts ic ON p.project_id = ic.project_id
LEFT JOIN temp_weather_counts wc ON p.project_id = wc.project_id
LEFT JOIN temp_dependency_counts depc ON p.project_id = depc.project_id;

-- Check what we created - THIS IS YOUR MAIN TABLE!
SELECT 
    COUNT(*) AS total_projects,
    AVG(risk_score) AS average_risk_score,
    MIN(risk_score) AS lowest_risk,
    MAX(risk_score) AS highest_risk
FROM FactProjectMetrics;

-- See risk distribution
SELECT 
    risk_category,
    COUNT(*) AS project_count
FROM FactProjectMetrics
GROUP BY risk_category;

-- View top 10 risky projects
SELECT 
    project_name,
    risk_score,
    risk_category,
    actual_delay_days
FROM FactProjectMetrics
ORDER BY risk_score DESC
LIMIT 10;

-- Clean up temporary tables (optional)
DROP TABLE IF EXISTS temp_task_counts;
DROP TABLE IF EXISTS temp_latest_task_status;
DROP TABLE IF EXISTS temp_task_progress;
DROP TABLE IF EXISTS temp_delay_counts;
DROP TABLE IF EXISTS temp_issue_counts;
DROP TABLE IF EXISTS temp_weather_counts;
DROP TABLE IF EXISTS temp_dependency_counts;

-- ----------------------------------------------------------------------------
-- Table: FactTaskProgress - Track progress over time
-- ----------------------------------------------------------------------------
-- What we're doing: Record every progress update with calculated metrics

CREATE TABLE FactTaskProgress (
    update_id INT PRIMARY KEY,
    task_id INT,
    project_id INT,
    update_date DATE,
    planned_pct_complete DECIMAL(10,2),
    actual_pct_complete DECIMAL(10,2),
    actual_start_date DATE,
    actual_finish_date DATE,              -- Can be NULL for unfinished tasks
    status_flag VARCHAR(50),
    delay_reason_code VARCHAR(100),
    remarks TEXT,
    
    -- Calculated fields
    progress_variance DECIMAL(10,2),      -- Difference: actual - planned
    progress_velocity DECIMAL(10,3),      -- Ratio: actual / planned
    days_since_start INT,
    is_completed TINYINT,
    is_delayed TINYINT,
    
    INDEX idx_task (task_id),
    INDEX idx_project (project_id),
    INDEX idx_date (update_date),
    INDEX idx_status (status_flag)
);

INSERT INTO FactTaskProgress
SELECT 
    update_id,
    task_id,
    project_id,
    update_date,
    planned_pct_complete,
    actual_pct_complete,
    actual_start_date,
    NULLIF(actual_finish_date, '') AS actual_finish_date,
    status_flag,
    delay_reason_code,
    remarks,
    
    -- How far behind/ahead is this task?
    actual_pct_complete - planned_pct_complete AS progress_variance,
    
    -- How fast is progress compared to plan?
    CASE 
        WHEN planned_pct_complete > 0 
        THEN ROUND(actual_pct_complete / planned_pct_complete, 3)
        ELSE NULL 
    END AS progress_velocity,
    
    -- How long has this task been running?
    CASE 
        WHEN actual_start_date IS NOT NULL 
        THEN DATEDIFF(update_date, actual_start_date)
        ELSE NULL 
    END AS days_since_start,
    
    -- Is task done?
    CASE WHEN actual_pct_complete >= 100 THEN 1 ELSE 0 END AS is_completed,
    
    -- Is task delayed?
    CASE WHEN actual_pct_complete < planned_pct_complete THEN 1 ELSE 0 END AS is_delayed
    
FROM task_progress_updates;

SELECT COUNT(*) AS total_progress_updates FROM FactTaskProgress;
-- Should show: 137,899 updates


-- ----------------------------------------------------------------------------
-- Table: FactIssues - Track all issues/NCR/RFI
-- ----------------------------------------------------------------------------

CREATE TABLE FactIssues (
    issue_id            INT PRIMARY KEY,
    project_id          INT,
    task_id             INT,
    issue_type          VARCHAR(50),
    severity            VARCHAR(50),
    reported_date       DATE,
    -- resolved_date REMOVED (column is completely empty)
    approval_delay_days INT,
    issue_status        VARCHAR(50),
    is_open             TINYINT,
    severity_score      INT,
    INDEX idx_project (project_id)
);

INSERT INTO FactIssues
SELECT 
    issue_id,
    project_id,
    task_id,
    issue_type,
    severity,
    reported_date,
    approval_delay_days,
    issue_status,
    CASE WHEN issue_status = 'Open'  THEN 1 ELSE 0 END AS is_open,
    CASE 
        WHEN severity = 'High'   THEN 3
        WHEN severity = 'Medium' THEN 2
        WHEN severity = 'Low'    THEN 1
        ELSE 0
    END AS severity_score
FROM issues_ncr_rfi;

-- Verify
SELECT COUNT(*) AS total_issues  FROM FactIssues;  -- Expected: 1,609
SELECT COUNT(*) AS open_issues   FROM FactIssues WHERE is_open = 1;
SELECT COUNT(*) AS high_severity FROM FactIssues WHERE severity_score = 3;

-- Preview
SELECT issue_id, issue_type, severity, issue_status, is_open, severity_score
FROM FactIssues LIMIT 5;


-- ----------------------------------------------------------------------------
-- Table: FactWeatherImpact - Track weather conditions
-- ----------------------------------------------------------------------------

CREATE TABLE FactWeatherImpact (
    weather_id INT PRIMARY KEY,
    project_id INT,
    date DATE,
    rainfall_mm DECIMAL(10,2),
    temperature_c DECIMAL(10,2),
    weather_severity VARCHAR(50),
    work_stop_flag CHAR(1),
    
    -- Calculated fields
    work_stopped TINYINT,
    severity_score INT,
    heavy_rainfall_flag TINYINT,
    extreme_temp_flag TINYINT,
    
    INDEX idx_project (project_id),
    INDEX idx_date (date)
);

INSERT INTO FactWeatherImpact
SELECT 
    weather_id,
    project_id,
    date,
    rainfall_mm,
    temperature_c,
    weather_severity,
    work_stop_flag,
    
    -- Convert flag to 0/1
    CASE WHEN work_stop_flag = 'Y' THEN 1 ELSE 0 END AS work_stopped,
    
    -- Weather severity as number
    CASE 
        WHEN weather_severity = 'Severe' THEN 3
        WHEN weather_severity = 'Moderate' THEN 2
        ELSE 1
    END AS severity_score,
    
    -- Was rainfall extreme?
    CASE WHEN rainfall_mm > 100 THEN 1 ELSE 0 END AS heavy_rainfall_flag,
    
    -- Was temperature extreme?
    CASE WHEN temperature_c > 40 OR temperature_c < 5 THEN 1 ELSE 0 END AS extreme_temp_flag
    
FROM weather_log;

SELECT COUNT(*) AS total_weather_records FROM FactWeatherImpact;
-- Should show: 20,824 records


-- ============================================================================
-- PART 3: CREATE USEFUL VIEWS (Pre-calculated reports)
-- ============================================================================
-- Views are like saved queries - they make Power BI even easier!

-- ----------------------------------------------------------------------------
-- View: Projects with their risk levels
-- ----------------------------------------------------------------------------

CREATE VIEW vw_ProjectRiskSummary AS
SELECT 
    project_id,
    project_name,
    contractor_name,
    current_project_status,
    risk_score,
    risk_category,
    actual_delay_days,
    -- Add a simple risk indicator
    CASE 
        WHEN risk_score > 60 THEN '🔴 HIGH RISK'
        WHEN risk_score > 30 THEN '🟡 MEDIUM RISK'
        ELSE '🟢 LOW RISK'
    END AS risk_indicator
FROM FactProjectMetrics
ORDER BY risk_score DESC;


-- ----------------------------------------------------------------------------
-- View: Contractor performance comparison
-- ----------------------------------------------------------------------------

CREATE VIEW vw_ContractorPerformance AS
SELECT 
    contractor_name,
    COUNT(project_id) AS total_projects,
    ROUND(AVG(actual_delay_days), 1) AS avg_delay_days,
    ROUND(AVG(risk_score), 1) AS avg_risk_score,
    SUM(CASE WHEN current_project_status = 'Delayed' THEN 1 ELSE 0 END) AS delayed_projects
FROM FactProjectMetrics
GROUP BY contractor_name
ORDER BY avg_risk_score DESC;


-- ----------------------------------------------------------------------------
-- View: Location-based risk analysis
-- ----------------------------------------------------------------------------

CREATE VIEW vw_LocationRisk AS
SELECT 
    state,
    city,
    COUNT(project_id) AS total_projects,
    ROUND(AVG(risk_score), 1) AS avg_risk_score,
    ROUND(AVG(actual_delay_days), 1) AS avg_delay_days,
    SUM(CASE WHEN risk_category = 'High Risk' THEN 1 ELSE 0 END) AS high_risk_projects
FROM FactProjectMetrics
GROUP BY state, city
ORDER BY avg_risk_score DESC;

-- ----------------------------------------------------------------------------
-- View: Critical Path Risk Analysis
-- ----------------------------------------------------------------------------

CREATE VIEW vw_CriticalPathRisk AS
SELECT 
    t.project_id,
    t.task_id,
    t.task_name,
    t.task_category,
    t.critical_flag,
    lp.actual_pct_complete,
    lp.status_flag,
    lp.delay_reason_code,
    CASE 
        WHEN lp.status_flag = 'Blocked'              THEN 'Critical Risk'
        WHEN lp.actual_pct_complete < 50             THEN 'High Risk'
        ELSE                                              'Medium Risk'
    END AS risk_level
FROM DimTasks t
JOIN (
    SELECT task_id, actual_pct_complete, status_flag, delay_reason_code
    FROM (
        SELECT task_id, actual_pct_complete, status_flag, delay_reason_code,
               ROW_NUMBER() OVER (PARTITION BY task_id ORDER BY update_date DESC) AS rn
        FROM task_progress_updates
    ) ranked
    WHERE rn = 1
) lp ON t.task_id = lp.task_id
WHERE t.critical_flag = 'Y';


-- ============================================================================
-- FINAL VERIFICATION - RUN THESE TO CONFIRM SUCCESS!
-- ============================================================================

-- Check 1: Verify all tables exist and have data
SELECT 'DimProjects' AS table_name, COUNT(*) AS row_count FROM DimProjects
UNION ALL SELECT 'DimTasks', COUNT(*) FROM DimTasks
UNION ALL SELECT 'DimDelayReasons', COUNT(*) FROM DimDelayReasons
UNION ALL SELECT 'FactProjectMetrics', COUNT(*) FROM FactProjectMetrics
UNION ALL SELECT 'FactTaskProgress', COUNT(*) FROM FactTaskProgress
UNION ALL SELECT 'FactIssues', COUNT(*) FROM FactIssues
UNION ALL SELECT 'FactWeatherImpact', COUNT(*) FROM FactWeatherImpact;

-- Expected results:
-- DimProjects: 28
-- DimTasks: 5,746
-- DimDelayReasons: 4
-- FactProjectMetrics: 28 (THIS IS YOUR MAIN TABLE!)
-- FactTaskProgress: 137,899
-- FactIssues: 1,609
-- FactWeatherImpact: 20,824


-- Check 2: Verify risk scores look correct
SELECT 
    project_name,
    risk_score,
    risk_category,
    actual_delay_days,
    current_project_status
FROM FactProjectMetrics
ORDER BY risk_score DESC
LIMIT 10;

-- You should see projects with different risk scores!


-- Check 3: Verify views work
SELECT * FROM vw_ProjectRiskSummary LIMIT 5;
SELECT * FROM vw_ContractorPerformance;
SELECT * FROM vw_LocationRisk;
SELECT * FROM vw_CriticalPathRisk;


-- ============================================================================
-- DONE







-- Update risk_score with VARIANCE-OPTIMIZED formula
UPDATE FactProjectMetrics
SET risk_score = ROUND(
    -- ========================================================================
    -- COMPONENT 1: DELAY DAYS (40% weight - HIGHEST because it varies most)
    -- ========================================================================
    -- Range: 5-119 days, 53.8% variance
    -- Using PERCENTILE-BASED thresholds from your actual data
    (CASE 
        WHEN actual_delay_days >= 96 THEN 100   -- Top 25% (very high delay)
        WHEN actual_delay_days >= 66 THEN 75    -- 50-75th percentile
        WHEN actual_delay_days >= 40 THEN 50    -- 25-50th percentile
        WHEN actual_delay_days >= 20 THEN 25    -- Bottom 25%
        ELSE 10                                  -- Minimal delay
    END) * 0.40
    
    -- ========================================================================
    -- COMPONENT 2: BLOCKED TASKS % (30% weight - 2nd highest variance)
    -- ========================================================================
    -- Range: 5.9-18.1%, 21.6% variance
    + (CASE 
        WHEN (blocked_tasks_count * 100.0 / NULLIF(total_tasks, 0)) >= 14.4 THEN 100  -- Top 25%
        WHEN (blocked_tasks_count * 100.0 / NULLIF(total_tasks, 0)) >= 12.6 THEN 70   -- Med-High
        WHEN (blocked_tasks_count * 100.0 / NULLIF(total_tasks, 0)) >= 11.8 THEN 40   -- Medium
        WHEN (blocked_tasks_count * 100.0 / NULLIF(total_tasks, 0)) >= 9.0 THEN 20    -- Low-Med
        ELSE 5                                                                          -- Very low
    END) * 0.30
    
    -- ========================================================================
    -- COMPONENT 3: WORK STOP DAYS (20% weight - good variance)
    -- ========================================================================
    -- Range: 50-99 days, 17.2% variance
    + (CASE 
        WHEN work_stop_days >= 80 THEN 100   -- Top 25%
        WHEN work_stop_days >= 74 THEN 70    -- Med-High
        WHEN work_stop_days >= 62 THEN 40    -- Medium
        WHEN work_stop_days >= 54 THEN 20    -- Low
        ELSE 5                                -- Very low
    END) * 0.20
    
    -- ========================================================================
    -- COMPONENT 4: OPEN ISSUES (10% weight - moderate variance)
    -- ========================================================================
    -- Range: 21-40, 18.1% variance
    + (CASE 
        WHEN open_issues >= 33 THEN 100   -- Top 25%
        WHEN open_issues >= 30 THEN 70    -- Med-High
        WHEN open_issues >= 27 THEN 40    -- Medium
        WHEN open_issues >= 23 THEN 20    -- Low
        ELSE 5                             -- Very low
    END) * 0.10
    
    -- ========================================================================
    -- REMOVED COMPONENTS (too little variance to be useful):
    -- - Progress Velocity (1.0% variance - all projects ~0.99)
    -- - Resource Delays (11.6% variance but all ~2000, doesn't discriminate)
    -- - Completion % (1.1% variance - all projects 92-95%)
    -- ========================================================================
    
, 2);

-- Update risk_category based on new scores
UPDATE FactProjectMetrics
SET risk_category = CASE 
        WHEN risk_score >= 60 THEN 'High Risk'
        WHEN risk_score >= 35 THEN 'Medium Risk'
        ELSE 'Low Risk'
    END;

-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================

-- Query 1: See the spread of risk scores
SELECT 
    project_name,
    actual_delay_days,
    ROUND(blocked_tasks_count * 100.0 / total_tasks, 1) AS blocked_pct,
    work_stop_days,
    open_issues,
    risk_score,
    risk_category
FROM FactProjectMetrics
ORDER BY risk_score DESC;

-- Query 2: Distribution by category (should now have all 3)
SELECT 
    risk_category,
    COUNT(*) AS project_count,
    ROUND(MIN(risk_score), 1) AS min_risk,
    ROUND(AVG(risk_score), 1) AS avg_risk,
    ROUND(MAX(risk_score), 1) AS max_risk
FROM FactProjectMetrics
GROUP BY risk_category
ORDER BY avg_risk DESC;

-- Query 3: Full range of risk scores
SELECT 
    MIN(risk_score) AS lowest_risk,
    ROUND(AVG(risk_score), 1) AS average_risk,
    MAX(risk_score) AS highest_risk,
    MAX(risk_score) - MIN(risk_score) AS score_range
FROM FactProjectMetrics;

-- ============================================================================

/*
The new formula focuses on the 4 metrics that ACTUALLY vary between your projects:

1. DELAY DAYS (40% weight):
   - Varies from 5 to 119 days (huge range!)
   - This is your BEST differentiator
   - Projects with 100+ days delay → High Risk
   - Projects with <20 days delay → Low Risk

2. BLOCKED TASKS % (30% weight):
   - Varies from 5.9% to 18.1%
   - Shows project execution problems
   - >14.4% blocked → High Risk
   - <9% blocked → Low Risk

3. WORK STOP DAYS (20% weight):
   - Varies from 50 to 99 days
   - External factor beyond control
   - But still impacts overall risk

4. OPEN ISSUES (10% weight):
   - Varies from 21 to 40 issues
   - Smaller weight because less variance

REMOVED METRICS:
- Progress Velocity: All projects 0.97-1.00 (useless)
- Resource Delays: All projects 1500-2300 (doesn't help distinguish)
- Completion %: All projects 92-96% (minimal difference)

Using percentile-based thresholds means:
- Top 25% of projects in each metric → High risk score
- Middle 50% → Medium risk score
- Bottom 25% → Low risk score

This creates a natural distribution across 28 projects!



select * from dimdelayreasons;
select * from dimprojects;
select * from dimtasks;
select * from factissues;
select * from factprojectmetrics;
select * from facttaskprogress;
select * from factweatherimpact;
select * from vw_contractorperformance;
select * from vw_criticalpathrisk;
select * from vw_locationrisk;
select * from vw_projectrisksummary;
