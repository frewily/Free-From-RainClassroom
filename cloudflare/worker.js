// ===== 基础配置 =====

const REPO = "frewily/Fuck-Yangtze-RainClassroom";

const GITHUB_API =
  `https://api.github.com/repos/${REPO}/actions/workflows/python-app.yml/dispatches`;

const SCHEDULE_URL =
  `https://raw.githubusercontent.com/${REPO}/main/data/course_schedule.json`;

// 是否启用真正的自动触发
// 先保持 false，验证通过后再改成 true
const AUTO_DISPATCH = true;

// 上课后 15 分钟内允许补触发
const TRIGGER_WINDOW_MINUTES = 15;

// 去重记录保留 14 天
const RECORD_TTL = 14 * 24 * 60 * 60;


// ===== 工具函数 =====

// HH:mm 转换为分钟
function toMinutes(time) {
  const [hour, minute] = time.split(":").map(Number);
  return hour * 60 + minute;
}

// 获取北京时间的日期和时间
function chinaTime(date) {
  const local = new Date(date.getTime() + 8 * 3600 * 1000);
  const iso = local.toISOString();

  return {
    date: iso.slice(0, 10),
    time: iso.slice(11, 16)
  };
}


// ===== GitHub API =====

async function triggerGitHub(env) {
  const response = await fetch(GITHUB_API, {
    method: "POST",
    headers: {
      "Accept": "application/vnd.github+json",
      "Authorization": `Bearer ${env.GITHUB_TOKEN}`,
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
      "User-Agent": "rainclassroom-scheduler"
    },
    body: JSON.stringify({
      ref: "main"
    })
  });

  if (response.status !== 204) {
    console.error("GitHub 请求失败：", response.status);
    throw new Error(`GitHub dispatch failed: ${response.status}`);
  }

  console.log("GitHub 已接受 Actions 触发请求");
}


// ===== 获取课表 =====

async function getSchedule() {
  const response = await fetch(SCHEDULE_URL, {
    headers: {
      "Accept": "application/json",
      "Cache-Control": "no-cache"
    }
  });

  if (!response.ok) {
    throw new Error(`获取课表失败：HTTP ${response.status}`);
  }

  const schedule = await response.json();

  if (!Array.isArray(schedule.classes)) {
    throw new Error("课表格式错误：classes 不是数组");
  }

  return schedule;
}


// ===== 核心调度逻辑 =====

async function checkSchedule(env, now, allowDispatch = false) {

  if (!env.TRIGGER_KV) {
    throw new Error("TRIGGER_KV 未绑定");
  }

  const schedule = await getSchedule();

  const { date, time } = chinaTime(now);

  console.log(`检查时间：${date} ${time}`);

  const currentMinutes = toMinutes(time);

  // 找出今天需要检查的课程
  const todayClasses = schedule.classes.filter(
    course => course.date === date
  );

  console.log(`今日课程数量：${todayClasses.length}`);

  // 将同一开始时间的课程合并
  const slots = new Map();

  for (const course of todayClasses) {

    const start = toMinutes(course.start);
    const end = toMinutes(course.end);

    // 只在上课后的前 15 分钟内触发
    if (
      currentMinutes < start ||
      currentMinutes >= start + TRIGGER_WINDOW_MINUTES ||
      currentMinutes >= end
    ) {
      continue;
    }

    if (!slots.has(course.start)) {
      slots.set(course.start, []);
    }

    slots.get(course.start).push(course.course);
  }

  const results = [];

  // 逐个处理需要触发的时间段
  for (const [start, courses] of slots) {

    const key = `rainclassroom:${date}:${start}`;

    // 查询是否已经触发
    const existing = await env.TRIGGER_KV.get(key);

    if (existing !== null) {
      console.log(`已触发过，跳过：${key}`);

      results.push({
        start,
        courses,
        status: "already_dispatched"
      });

      continue;
    }

    // 演练模式：只判断，不触发、不写 KV
    if (!allowDispatch) {
      console.log(`演练：应该触发 ${key}`);

      results.push({
        start,
        courses,
        status: "would_dispatch"
      });

      continue;
    }

    // 正式模式：请求 GitHub
    await triggerGitHub(env);

    // GitHub 接受请求后记录状态
    await env.TRIGGER_KV.put(
      key,
      JSON.stringify({
        status: "dispatched",
        date,
        start,
        courses,
        dispatchedAt: new Date().toISOString()
      }),
      {
        expirationTtl: RECORD_TTL
      }
    );

    console.log(`已记录触发状态：${key}`);

    results.push({
      start,
      courses,
      status: "dispatched"
    });
  }

  console.log("本次调度检查完成");

  return {
    date,
    time,
    dispatchEnabled: allowDispatch,
    results
  };
}


// ===== Worker 入口 =====

export default {

  async fetch(request, env) {

    const url = new URL(request.url);

    // GET /：查看服务状态
    if (request.method === "GET" && url.pathname === "/") {
      return new Response("RainClassroom Scheduler is running!");
    }

    if (!["/test", "/preview"].includes(url.pathname)) {
      return new Response("Not Found", { status: 404 });
    }

    if (request.method !== "POST") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    if (!env.TEST_TRIGGER_KEY || !env.GITHUB_TOKEN) {
      return new Response("Server configuration error", {
        status: 500
      });
    }

    // 验证测试密钥
    const authorization = request.headers.get("Authorization");

    if (authorization !== `Bearer ${env.TEST_TRIGGER_KEY}`) {
      return new Response("Unauthorized", { status: 401 });
    }

    try {

      // POST /test：手动触发真实 Actions
      if (url.pathname === "/test") {

        await triggerGitHub(env);

        return new Response(
          "GitHub Actions dispatch accepted!",
          { status: 200 }
        );
      }

      // POST /preview：模拟指定时间检查课表
      if (url.pathname === "/preview") {

        const body = await request.json();

        // 格式：2026-10-20T08:00
        if (
          typeof body.at !== "string" ||
          !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(body.at)
        ) {
          return new Response("Invalid time format", {
            status: 400
          });
        }

        const simulated = new Date(`${body.at}+08:00`);

        if (Number.isNaN(simulated.getTime())) {
          return new Response("Invalid date", {
            status: 400
          });
        }

        // 永远只演练，不触发 GitHub
        const result = await checkSchedule(
          env,
          simulated,
          false
        );

        return Response.json(result);
      }

    } catch (error) {
      console.error("请求处理失败：", error.message);

      return new Response("Request failed", {
        status: 500
      });
    }
  },

  // Cloudflare Cron 自动调用
  async scheduled(controller, env, ctx) {

    console.log("Cron 调度开始");

    await checkSchedule(
      env,
      new Date(),
      AUTO_DISPATCH
    );
  }
};