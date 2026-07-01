

USE PaymentFunnelAnalysis;
GO

DROP TABLE IF EXISTS funnel_events;
GO

SELECT
    User_ID                          AS user_id,
    Session_ID                       AS session_id,
    CAST(Event_Time AS DATETIME2)    AS event_time,
    Event                            AS event_name,
    Device                           AS device,
    Region                           AS region,
    Channel                          AS channel,
    Product_Category                 AS product_category,
    CAST(Revenue AS DECIMAL(10,2))   AS revenue,
    CAST(
        CASE WHEN CAST(Bonus_Flag AS NVARCHAR(10)) = 'No' THEN 1 ELSE 0 END
    AS BIT)                          AS is_purchase
INTO funnel_events
FROM funnel_raw;
GO

SELECT TOP 10 * FROM funnel_events;

-- This step is to do a duplicate check
SELECT user_id, session_id, event_name, COUNT(*) AS cnt
FROM funnel_events
GROUP BY user_id, session_id, event_name
HAVING COUNT(*) > 1;


-- This step is done to check any null values
SELECT
    SUM(CASE WHEN user_id IS NULL THEN 1 ELSE 0 END)          AS null_user,
    SUM(CASE WHEN session_id IS NULL THEN 1 ELSE 0 END)        AS null_session,
    SUM(CASE WHEN event_time IS NULL THEN 1 ELSE 0 END)        AS null_time,
    SUM(CASE WHEN event_name IS NULL THEN 1 ELSE 0 END)        AS null_event,
    SUM(CASE WHEN revenue IS NULL THEN 1 ELSE 0 END)           AS null_revenue
FROM funnel_events;


-- Event distribution
SELECT event_name, COUNT(*) AS event_count
FROM funnel_events
GROUP BY event_name
ORDER BY event_count DESC;


-- ============================================================
-- SECTION 1: OVERALL FUNNEL CONVERSION
-- Business question: How many users reach each stage and
-- where is the biggest drop-off?
-- ============================================================

WITH stage_counts AS (
    SELECT
        event_name,
        COUNT(DISTINCT session_id) AS sessions
    FROM funnel_events
    GROUP BY event_name
),
ordered AS (
    SELECT
        event_name,
        sessions,
        CASE event_name
            WHEN 'Browse'      THEN 1
            WHEN 'Add to Cart' THEN 2
            WHEN 'Checkout'    THEN 3
            WHEN 'Purchase'    THEN 4
        END AS stage_order
    FROM stage_counts
)
SELECT
    stage_order,
    event_name                                                        AS funnel_stage,
    sessions                                                          AS users_at_stage,
    ROUND(sessions * 100.0 / MAX(sessions) OVER (), 2)               AS pct_of_top_funnel,
    LAG(sessions) OVER (ORDER BY stage_order)                         AS prev_stage_users,
    ROUND(
        (LAG(sessions) OVER (ORDER BY stage_order) - sessions) * 100.0
        / NULLIF(LAG(sessions) OVER (ORDER BY stage_order), 0),
    2)                                                                AS drop_off_pct
FROM ordered
ORDER BY stage_order;

-- ============================================================
-- SECTION 2: STAGE-TO-STAGE CONVERSION RATES
-- Business question: What exact percentage of users advance
-- from each stage to the next?
-- ============================================================

WITH user_stages AS (
    SELECT
        session_id,
        MAX(CASE WHEN event_name = 'Browse'      THEN 1 ELSE 0 END) AS reached_browse,
        MAX(CASE WHEN event_name = 'Add to Cart' THEN 1 ELSE 0 END) AS reached_cart,
        MAX(CASE WHEN event_name = 'Checkout'    THEN 1 ELSE 0 END) AS reached_checkout,
        MAX(CASE WHEN event_name = 'Purchase'    THEN 1 ELSE 0 END) AS reached_purchase
    FROM funnel_events
    GROUP BY session_id
)
SELECT
    'Browse to Add to Cart'           AS transition,
    SUM(reached_browse)               AS from_stage,
    SUM(reached_cart)                 AS to_stage,
    ROUND(SUM(reached_cart) * 100.0
        / NULLIF(SUM(reached_browse), 0), 2)  AS conversion_rate_pct
FROM user_stages

UNION ALL

SELECT
    'Add to Cart to Checkout',
    SUM(reached_cart),
    SUM(reached_checkout),
    ROUND(SUM(reached_checkout) * 100.0
        / NULLIF(SUM(reached_cart), 0), 2)
FROM user_stages

UNION ALL

SELECT
    'Checkout to Purchase',
    SUM(reached_checkout),
    SUM(reached_purchase),
    ROUND(SUM(reached_purchase) * 100.0
        / NULLIF(SUM(reached_checkout), 0), 2)
FROM user_stages

UNION ALL

SELECT
    'Browse to Purchase (Overall)',
    SUM(reached_browse),
    SUM(reached_purchase),
    ROUND(SUM(reached_purchase) * 100.0
        / NULLIF(SUM(reached_browse), 0), 2)
FROM user_stages;

-- ============================================================
-- SECTION 3: FUNNEL BY DEVICE TYPE
-- Business question: Which device converts best end-to-end?
-- Where does mobile underperform?
-- ============================================================

WITH device_stages AS (
    SELECT
        device,
        event_name,
        COUNT(DISTINCT session_id) AS sessions
    FROM funnel_events
    GROUP BY device, event_name
),
pivoted AS (
    SELECT
        device,
        MAX(CASE WHEN event_name = 'Browse'      THEN sessions END) AS [browse],
        MAX(CASE WHEN event_name = 'Add to Cart' THEN sessions END) AS [add_to_cart],
        MAX(CASE WHEN event_name = 'Checkout'    THEN sessions END) AS [checkout],
        MAX(CASE WHEN event_name = 'Purchase'    THEN sessions END) AS [purchase]
    FROM device_stages
    GROUP BY device
)
SELECT
    device,
    [browse],
    [add_to_cart],
    [checkout],
    [purchase],
    ROUND([add_to_cart] * 100.0 / NULLIF([browse],       0), 2) AS browse_to_cart_pct,
    ROUND([checkout]    * 100.0 / NULLIF([add_to_cart],  0), 2) AS cart_to_checkout_pct,
    ROUND([purchase]    * 100.0 / NULLIF([checkout],     0), 2) AS checkout_to_purchase_pct,
    ROUND([purchase]    * 100.0 / NULLIF([browse],       0), 2) AS overall_conversion_pct
FROM pivoted
ORDER BY overall_conversion_pct DESC;

-- ============================================================
-- SECTION 4: FUNNEL BY ACQUISITION CHANNEL
-- Business question: Which marketing channel brings the
-- highest quality, purchase-ready users?
-- ============================================================

WITH channel_stages AS (
    SELECT
        channel,
        event_name,
        COUNT(DISTINCT session_id) AS sessions
    FROM funnel_events
    GROUP BY channel, event_name
),
pivoted AS (
    SELECT
        channel,
        MAX(CASE WHEN event_name = 'Browse'      THEN sessions END) AS [browse],
        MAX(CASE WHEN event_name = 'Add to Cart' THEN sessions END) AS [add_to_cart],
        MAX(CASE WHEN event_name = 'Checkout'    THEN sessions END) AS [checkout],
        MAX(CASE WHEN event_name = 'Purchase'    THEN sessions END) AS [purchase]
    FROM channel_stages
    GROUP BY channel
)
SELECT
    channel,
    [browse],
    [add_to_cart],
    [checkout],
    [purchase],
    ROUND([browse_to_cart]       , 2) AS browse_to_cart_pct,
    ROUND([cart_to_checkout]     , 2) AS cart_to_checkout_pct,
    ROUND([checkout_to_purchase] , 2) AS checkout_to_purchase_pct,
    ROUND([overall_conversion]   , 2) AS overall_conversion_pct
FROM (
    SELECT
        channel,
        [browse],
        [add_to_cart],
        [checkout],
        [purchase],
        [add_to_cart] * 100.0 / NULLIF([browse],      0) AS [browse_to_cart],
        [checkout]    * 100.0 / NULLIF([add_to_cart],  0) AS [cart_to_checkout],
        [purchase]    * 100.0 / NULLIF([checkout],     0) AS [checkout_to_purchase],
        [purchase]    * 100.0 / NULLIF([browse],       0) AS [overall_conversion]
    FROM pivoted
) AS calc
ORDER BY overall_conversion_pct DESC;

-- ============================================================
-- SECTION 5: FUNNEL BY PRODUCT CATEGORY
-- Business question: Which categories lose users most at
-- checkout? Are some categories easier to convert?
-- ============================================================

WITH cat_stages AS (
    SELECT
        product_category,
        event_name,
        COUNT(DISTINCT session_id) AS sessions
    FROM funnel_events
    GROUP BY product_category, event_name
),
pivoted AS (
    SELECT
        product_category,
        MAX(CASE WHEN event_name = 'Browse'      THEN sessions END) AS [browse],
        MAX(CASE WHEN event_name = 'Add to Cart' THEN sessions END) AS [add_to_cart],
        MAX(CASE WHEN event_name = 'Checkout'    THEN sessions END) AS [checkout],
        MAX(CASE WHEN event_name = 'Purchase'    THEN sessions END) AS [purchase]
    FROM cat_stages
    GROUP BY product_category
)
SELECT
    product_category,
    [browse],
    [add_to_cart],
    [checkout],
    [purchase],
    ROUND([add_to_cart] * 100.0 / NULLIF([browse],      0), 2) AS browse_to_cart_pct,
    ROUND([checkout]    * 100.0 / NULLIF([add_to_cart], 0), 2) AS cart_to_checkout_pct,
    ROUND([purchase]    * 100.0 / NULLIF([checkout],    0), 2) AS checkout_to_purchase_pct,
    ROUND([purchase]    * 100.0 / NULLIF([browse],      0), 2) AS overall_conversion_pct
FROM pivoted
ORDER BY overall_conversion_pct DESC;

-- ============================================================
-- SECTION 6: FUNNEL BY REGION
-- Business question: Are there geographic performance gaps
-- that suggest localisation opportunities?
-- ============================================================

WITH region_stages AS (
    SELECT
        region,
        event_name,
        COUNT(DISTINCT session_id) AS sessions
    FROM funnel_events
    GROUP BY region, event_name
),
pivoted AS (
    SELECT
        region,
        MAX(CASE WHEN event_name = 'Browse'      THEN sessions END) AS [browse],
        MAX(CASE WHEN event_name = 'Add to Cart' THEN sessions END) AS [add_to_cart],
        MAX(CASE WHEN event_name = 'Checkout'    THEN sessions END) AS [checkout],
        MAX(CASE WHEN event_name = 'Purchase'    THEN sessions END) AS [purchase]
    FROM region_stages
    GROUP BY region
)
SELECT
    region,
    [browse],
    [add_to_cart],
    [checkout],
    [purchase],
    ROUND([add_to_cart] * 100.0 / NULLIF([browse],      0), 2) AS browse_to_cart_pct,
    ROUND([checkout]    * 100.0 / NULLIF([add_to_cart], 0), 2) AS cart_to_checkout_pct,
    ROUND([purchase]    * 100.0 / NULLIF([checkout],    0), 2) AS checkout_to_purchase_pct,
    ROUND([purchase]    * 100.0 / NULLIF([browse],      0), 2) AS overall_conversion_pct
FROM pivoted
ORDER BY overall_conversion_pct DESC;

-- ============================================================
-- SECTION 7: TIME TO CONVERT ANALYSIS
-- Business question: How long does the purchase journey take?
-- Do faster sessions convert better?
-- ============================================================

WITH session_times AS (
    SELECT
        session_id,
        MIN(event_time)                                    AS session_start,
        MAX(event_time)                                    AS session_end,
        MAX(CASE WHEN event_name = 'Purchase' 
            THEN 1 ELSE 0 END)                             AS converted,
        DATEDIFF(SECOND, MIN(event_time), MAX(event_time)) 
            / 60.0                                         AS session_duration_mins
    FROM funnel_events
    GROUP BY session_id
)
SELECT
    CASE WHEN converted = 1 
        THEN 'Converted' 
        ELSE 'Not Converted' 
    END                                                    AS outcome,
    COUNT(*)                                               AS session_count,
    ROUND(AVG(session_duration_mins), 2)                   AS avg_duration_mins,
    ROUND(MIN(session_duration_mins), 2)                   AS min_duration_mins,
    ROUND(MAX(session_duration_mins), 2)                   AS max_duration_mins,
    ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP
        (ORDER BY session_duration_mins)
        OVER (PARTITION BY converted), 2)                  AS median_duration_mins
FROM session_times
GROUP BY converted, session_duration_mins
ORDER BY converted DESC;

-- ============================================================
-- SECTION 8: REVENUE ANALYSIS
-- Business question: Which segments generate the most revenue?
-- Where should we focus to grow overall sales?
-- ============================================================

-- 8a: Total and average revenue by channel
SELECT
    channel,
    COUNT(DISTINCT session_id)                    AS purchases,
    ROUND(SUM(revenue), 2)                        AS total_revenue,
    ROUND(AVG(revenue), 2)                        AS avg_order_value,
    ROUND(MIN(revenue), 2)                        AS min_order_value,
    ROUND(MAX(revenue), 2)                        AS max_order_value
FROM funnel_events
WHERE event_name = 'Purchase'
GROUP BY channel
ORDER BY total_revenue DESC;

-- 8b: Revenue by device
SELECT
    device,
    COUNT(DISTINCT session_id)                    AS purchases,
    ROUND(SUM(revenue), 2)                        AS total_revenue,
    ROUND(AVG(revenue), 2)                        AS avg_order_value,
    ROUND(MIN(revenue), 2)                        AS min_order_value,
    ROUND(MAX(revenue), 2)                        AS max_order_value
FROM funnel_events
WHERE event_name = 'Purchase'
GROUP BY device
ORDER BY total_revenue DESC;

-- 8c: Revenue by product category
SELECT
    product_category,
    COUNT(DISTINCT session_id)                    AS purchases,
    ROUND(SUM(revenue), 2)                        AS total_revenue,
    ROUND(AVG(revenue), 2)                        AS avg_order_value,
    ROUND(MIN(revenue), 2)                        AS min_order_value,
    ROUND(MAX(revenue), 2)                        AS max_order_value
FROM funnel_events
WHERE event_name = 'Purchase'
GROUP BY product_category
ORDER BY total_revenue DESC;

-- 8d: Revenue by region
SELECT
    region,
    COUNT(DISTINCT session_id)                    AS purchases,
    ROUND(SUM(revenue), 2)                        AS total_revenue,
    ROUND(AVG(revenue), 2)                        AS avg_order_value,
    ROUND(MIN(revenue), 2)                        AS min_order_value,
    ROUND(MAX(revenue), 2)                        AS max_order_value
FROM funnel_events
WHERE event_name = 'Purchase'
GROUP BY region
ORDER BY total_revenue DESC;

-- ============================================================
-- SECTION 9: DROP-OFF SEGMENTATION
-- Business question: Which combination of channel and device
-- has the worst checkout abandonment?
-- ============================================================

WITH session_max_stage AS (
    SELECT
        session_id,
        device,
        channel,
        region,
        product_category,
        MAX(CASE
            WHEN event_name = 'Purchase'    THEN 4
            WHEN event_name = 'Checkout'    THEN 3
            WHEN event_name = 'Add to Cart' THEN 2
            WHEN event_name = 'Browse'      THEN 1
        END)                                        AS max_stage_reached
    FROM funnel_events
    GROUP BY session_id, device, channel, region, product_category
)
SELECT
    channel,
    device,
    COUNT(*)                                                        AS total_sessions,
    SUM(CASE WHEN max_stage_reached >= 2 THEN 1 ELSE 0 END)        AS reached_cart,
    SUM(CASE WHEN max_stage_reached >= 3 THEN 1 ELSE 0 END)        AS reached_checkout,
    SUM(CASE WHEN max_stage_reached =  4 THEN 1 ELSE 0 END)        AS reached_purchase,
    ROUND(
        SUM(CASE WHEN max_stage_reached = 4 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(COUNT(*), 0), 2
    )                                                               AS overall_conversion_pct,
    ROUND(
        SUM(CASE WHEN max_stage_reached = 4 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(CASE WHEN max_stage_reached >= 3 THEN 1 ELSE 0 END), 0), 2
    )                                                               AS checkout_to_purchase_pct
FROM session_max_stage
GROUP BY channel, device
ORDER BY overall_conversion_pct DESC;

-- ============================================================
-- SECTION 10: DAILY TREND ANALYSIS
-- Business question: Are conversion rates improving over time?
-- Are there day-of-week patterns worth acting on?
-- ============================================================

-- 10a: Daily funnel volume
SELECT
    CAST(event_time AS DATE)                                        AS event_date,
    COUNT(DISTINCT CASE WHEN event_name = 'Browse'
        THEN session_id END)                                        AS browse_sessions,
    COUNT(DISTINCT CASE WHEN event_name = 'Add to Cart'
        THEN session_id END)                                        AS cart_sessions,
    COUNT(DISTINCT CASE WHEN event_name = 'Checkout'
        THEN session_id END)                                        AS checkout_sessions,
    COUNT(DISTINCT CASE WHEN event_name = 'Purchase'
        THEN session_id END)                                        AS purchase_sessions,
    ROUND(
        COUNT(DISTINCT CASE WHEN event_name = 'Purchase'
            THEN session_id END) * 100.0
        / NULLIF(COUNT(DISTINCT CASE WHEN event_name = 'Browse'
            THEN session_id END), 0), 2
    )                                                               AS daily_conversion_pct
FROM funnel_events
GROUP BY CAST(event_time AS DATE)
ORDER BY event_date;

-- 10b: Day of week pattern
SELECT
    DATENAME(WEEKDAY, event_time)                                   AS day_of_week,
    DATEPART(WEEKDAY, event_time)                                   AS dow_number,
    COUNT(DISTINCT CASE WHEN event_name = 'Browse'
        THEN session_id END)                                        AS browse_sessions,
    COUNT(DISTINCT CASE WHEN event_name = 'Purchase'
        THEN session_id END)                                        AS purchase_sessions,
    ROUND(
        COUNT(DISTINCT CASE WHEN event_name = 'Purchase'
            THEN session_id END) * 100.0
        / NULLIF(COUNT(DISTINCT CASE WHEN event_name = 'Browse'
            THEN session_id END), 0), 2
    )                                                               AS conversion_pct
FROM funnel_events
GROUP BY DATENAME(WEEKDAY, event_time), DATEPART(WEEKDAY, event_time)
ORDER BY dow_number;

-- ============================================================
-- SECTION 11: CART ABANDONMENT DEEP DIVE
-- Business question: Of all users who added to cart, how many
-- abandoned before purchase and at exactly which step?
-- ============================================================

-- Overall abandonment breakdown
WITH session_flags AS (
    SELECT
        session_id,
        device,
        channel,
        product_category,
        region,
        MAX(CASE WHEN event_name = 'Browse'      THEN 1 ELSE 0 END) AS did_browse,
        MAX(CASE WHEN event_name = 'Add to Cart' THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN event_name = 'Checkout'    THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN event_name = 'Purchase'    THEN 1 ELSE 0 END) AS did_purchase
    FROM funnel_events
    GROUP BY session_id, device, channel, product_category, region
)
SELECT
    abandonment_type,
    sessions,
    ROUND(sessions * 100.0 / SUM(sessions) OVER (), 2) AS pct_of_all_sessions
FROM (
    SELECT
        'Browsed only, left before cart'        AS abandonment_type,
        COUNT(*)                                AS sessions
    FROM session_flags
    WHERE did_browse = 1 AND did_cart = 0

    UNION ALL

    SELECT
        'Added to cart, left before checkout',
        COUNT(*)
    FROM session_flags
    WHERE did_cart = 1 AND did_checkout = 0

    UNION ALL

    SELECT
        'Reached checkout, left before purchase',
        COUNT(*)
    FROM session_flags
    WHERE did_checkout = 1 AND did_purchase = 0

    UNION ALL

    SELECT
        'Completed purchase',
        COUNT(*)
    FROM session_flags
    WHERE did_purchase = 1
) AS abandonment_summary
ORDER BY sessions DESC;


-- Abandonment by device
WITH session_flags AS (
    SELECT
        session_id,
        device,
        channel,
        product_category,
        region,
        MAX(CASE WHEN event_name = 'Browse'      THEN 1 ELSE 0 END) AS did_browse,
        MAX(CASE WHEN event_name = 'Add to Cart' THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN event_name = 'Checkout'    THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN event_name = 'Purchase'    THEN 1 ELSE 0 END) AS did_purchase
    FROM funnel_events
    GROUP BY session_id, device, channel, product_category, region
)
SELECT
    device,
    SUM(CASE WHEN did_cart = 1 AND did_checkout = 0 THEN 1 ELSE 0 END)     AS cart_abandonment,
    SUM(CASE WHEN did_checkout = 1 AND did_purchase = 0 THEN 1 ELSE 0 END)  AS checkout_abandonment,
    SUM(CASE WHEN did_purchase = 1 THEN 1 ELSE 0 END)                       AS completed_purchase,
    ROUND(
        SUM(CASE WHEN did_cart = 1 AND did_checkout = 0 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(did_cart), 0), 2
    )                                                                        AS cart_abandonment_pct,
    ROUND(
        SUM(CASE WHEN did_checkout = 1 AND did_purchase = 0 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(did_checkout), 0), 2
    )                                                                        AS checkout_abandonment_pct
FROM session_flags
GROUP BY device
ORDER BY checkout_abandonment_pct DESC;


-- Abandonment by channel
WITH session_flags AS (
    SELECT
        session_id,
        device,
        channel,
        product_category,
        region,
        MAX(CASE WHEN event_name = 'Browse'      THEN 1 ELSE 0 END) AS did_browse,
        MAX(CASE WHEN event_name = 'Add to Cart' THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN event_name = 'Checkout'    THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN event_name = 'Purchase'    THEN 1 ELSE 0 END) AS did_purchase
    FROM funnel_events
    GROUP BY session_id, device, channel, product_category, region
)
SELECT
    channel,
    SUM(CASE WHEN did_cart = 1 AND did_checkout = 0 THEN 1 ELSE 0 END)     AS cart_abandonment,
    SUM(CASE WHEN did_checkout = 1 AND did_purchase = 0 THEN 1 ELSE 0 END)  AS checkout_abandonment,
    SUM(CASE WHEN did_purchase = 1 THEN 1 ELSE 0 END)                       AS completed_purchase,
    ROUND(
        SUM(CASE WHEN did_cart = 1 AND did_checkout = 0 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(did_cart), 0), 2
    )                                                                        AS cart_abandonment_pct,
    ROUND(
        SUM(CASE WHEN did_checkout = 1 AND did_purchase = 0 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(did_checkout), 0), 2
    )                                                                        AS checkout_abandonment_pct
FROM session_flags
GROUP BY channel
ORDER BY checkout_abandonment_pct DESC;


-- Abandonment by product category
WITH session_flags AS (
    SELECT
        session_id,
        device,
        channel,
        product_category,
        region,
        MAX(CASE WHEN event_name = 'Browse'      THEN 1 ELSE 0 END) AS did_browse,
        MAX(CASE WHEN event_name = 'Add to Cart' THEN 1 ELSE 0 END) AS did_cart,
        MAX(CASE WHEN event_name = 'Checkout'    THEN 1 ELSE 0 END) AS did_checkout,
        MAX(CASE WHEN event_name = 'Purchase'    THEN 1 ELSE 0 END) AS did_purchase
    FROM funnel_events
    GROUP BY session_id, device, channel, product_category, region
)
SELECT
    product_category,
    SUM(CASE WHEN did_cart = 1 AND did_checkout = 0 THEN 1 ELSE 0 END)     AS cart_abandonment,
    SUM(CASE WHEN did_checkout = 1 AND did_purchase = 0 THEN 1 ELSE 0 END)  AS checkout_abandonment,
    SUM(CASE WHEN did_purchase = 1 THEN 1 ELSE 0 END)                       AS completed_purchase,
    ROUND(
        SUM(CASE WHEN did_cart = 1 AND did_checkout = 0 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(did_cart), 0), 2
    )                                                                        AS cart_abandonment_pct,
    ROUND(
        SUM(CASE WHEN did_checkout = 1 AND did_purchase = 0 THEN 1 ELSE 0 END) * 100.0
        / NULLIF(SUM(did_checkout), 0), 2
    )                                                                        AS checkout_abandonment_pct
FROM session_flags
GROUP BY product_category
ORDER BY checkout_abandonment_pct DESC;

-- ============================================================
-- SECTION 12: MASTER TABLE FOR BUILDING DASHBOARD
-- One flat session-level table with all attributes needed
-- for every Tableau chart in the dashboard
-- This table will help me creating a Tableau dashboard
-- ============================================================

DROP TABLE IF EXISTS funnel_tableau_export;
GO

WITH session_attributes AS (
    SELECT
        session_id,
        user_id,
        device,
        region,
        channel,
        product_category
    FROM (
        SELECT
            session_id,
            user_id,
            device,
            region,
            channel,
            product_category,
            ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY event_time) AS rn
        FROM funnel_events
    ) AS ranked
    WHERE rn = 1
),
session_stages AS (
    SELECT
        session_id,
        MIN(event_time)                                             AS session_start,
        MAX(event_time)                                             AS session_end,
        DATEDIFF(SECOND, MIN(event_time), MAX(event_time)) / 60.0  AS duration_mins,
        MAX(CASE WHEN event_name = 'Browse'      THEN 1 ELSE 0 END) AS reached_browse,
        MAX(CASE WHEN event_name = 'Add to Cart' THEN 1 ELSE 0 END) AS reached_cart,
        MAX(CASE WHEN event_name = 'Checkout'    THEN 1 ELSE 0 END) AS reached_checkout,
        MAX(CASE WHEN event_name = 'Purchase'    THEN 1 ELSE 0 END) AS reached_purchase,
        MAX(CASE
            WHEN event_name = 'Purchase'    THEN 'Purchase'
            WHEN event_name = 'Checkout'    THEN 'Checkout'
            WHEN event_name = 'Add to Cart' THEN 'Add to Cart'
            ELSE 'Browse'
        END)                                                        AS furthest_stage,
        MAX(CASE
            WHEN event_name = 'Purchase'    THEN 4
            WHEN event_name = 'Checkout'    THEN 3
            WHEN event_name = 'Add to Cart' THEN 2
            ELSE 1
        END)                                                        AS furthest_stage_num,
        SUM(revenue)                                                AS session_revenue
    FROM funnel_events
    GROUP BY session_id
)
SELECT
    a.session_id,
    a.user_id,
    a.device,
    a.region,
    a.channel,
    a.product_category,
    s.session_start,
    s.session_end,
    CAST(s.session_start AS DATE)                                   AS session_date,
    DATENAME(WEEKDAY, s.session_start)                              AS day_of_week,
    ROUND(s.duration_mins, 2)                                       AS session_duration_mins,
    s.reached_browse,
    s.reached_cart,
    s.reached_checkout,
    s.reached_purchase,
    s.furthest_stage,
    s.furthest_stage_num,
    ROUND(s.session_revenue, 2)                                     AS revenue,
    CASE WHEN s.reached_purchase = 1
        THEN 'Converted'
        ELSE 'Not Converted'
    END                                                             AS converted
INTO funnel_tableau_export
FROM session_attributes a
JOIN session_stages s ON a.session_id = s.session_id
ORDER BY a.session_id;
GO

-- Verify the export table
SELECT TOP 10 * FROM funnel_tableau_export;

-- Total sessions count
SELECT COUNT(*) AS total_sessions FROM funnel_tableau_export;

-- Quick sanity check on converted vs not converted
SELECT
    converted,
    COUNT(*)                        AS sessions,
    ROUND(SUM(revenue), 2)          AS total_revenue,
    ROUND(AVG(revenue), 2)          AS avg_revenue
FROM funnel_tableau_export
GROUP BY converted;