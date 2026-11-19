// Навантажувальний сценарій SmartBite (k6): профіль «мало записів, багато читань».
//
// Один віртуальний користувач у циклі:
//   1 запис  — POST /generate-plan (генерує і зберігає план; важка операція по CPU)
//   9 читань — 4× список планів, 2× щойно створений план, 2× випадковий план
//              зі списку, 1× довідник інгредієнтів
//
// Фази: наростання 0→N за 3 хв, стале навантаження N 5 хв, спад N→0 за 2 хв.
//
// Запуск:
//   k6 run -e BASE_URL=http://<alb-dns> loadtest/smartbite.js
// Параметри (-e NAME=value):
//   BASE_URL   адреса сервісу (обов'язково)
//   VUS        N — кількість користувачів на сталому навантаженні (за замовч. 8)
//   CACHE      on | off — off додає заголовок X-Cache-Bypass: 1 (прогін «без кешу»)
//   THINK      пауза між діями користувача, с (за замовч. 1)
//   RAMP_UP, STEADY, RAMP_DOWN — тривалість фаз (за замовч. 3m, 5m, 2m)

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate } from "k6/metrics";
import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js";

const BASE_URL = (__ENV.BASE_URL || "").replace(/\/$/, "");
const PREFIX = __ENV.API_PREFIX || "/make-server-fd5d4174";
const N = Number(__ENV.VUS || 8);
const CACHE = (__ENV.CACHE || "on").toLowerCase();
const THINK = Number(__ENV.THINK || 1);

if (!BASE_URL) {
  throw new Error("Задайте адресу: k6 run -e BASE_URL=http://... loadtest/smartbite.js");
}

const API = `${BASE_URL}${PREFIX}`;
const JSON_HEADERS = { "Content-Type": "application/json" };
const READ_HEADERS = CACHE === "off" ? { "X-Cache-Bypass": "1" } : {};

// Частка влучань у кеш для списку планів (за заголовком X-Cache).
const cacheHit = new Rate("cache_hit");

export const options = {
  scenarios: {
    users: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: [
        { duration: __ENV.RAMP_UP || "3m", target: N },
        { duration: __ENV.STEADY || "5m", target: N },
        { duration: __ENV.RAMP_DOWN || "2m", target: 0 },
      ],
      gracefulRampDown: "30s",
    },
  },
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
  thresholds: {
    http_req_failed: ["rate<0.01"],
    "http_req_duration{op:read}": ["p(95)<1000"],
    // Пороги, які завжди виконуються: лише щоб k6 показав ці підметрики в підсумку.
    "http_req_duration{op:write}": ["p(95)<600000"],
    "http_req_duration{name:GET /plans}": ["p(95)<600000"],
    "http_req_duration{name:GET /plans/{id}}": ["p(95)<600000"],
    cache_hit: ["rate>=0"],
  },
};

function think() {
  sleep(THINK * (0.5 + Math.random())); // 0.5×–1.5× THINK, щоб користувачі не йшли «в ногу»
}

function listPlans() {
  const res = http.get(`${API}/plans`, {
    headers: READ_HEADERS,
    tags: { name: "GET /plans", op: "read" },
  });
  check(res, { "list 200": (r) => r.status === 200 });
  const x = res.headers["X-Cache"];
  if (x === "HIT" || x === "MISS") cacheHit.add(x === "HIT");
  try {
    return res.json("plans") || [];
  } catch (_) {
    return [];
  }
}

function getPlan(id) {
  const res = http.get(`${API}/plans/${id}`, {
    headers: READ_HEADERS,
    tags: { name: "GET /plans/{id}", op: "read" },
  });
  check(res, { "plan 200": (r) => r.status === 200 });
}

function getIngredients() {
  const res = http.get(`${API}/ingredients`, {
    tags: { name: "GET /ingredients", op: "read" },
  });
  check(res, { "ingredients 200": (r) => r.status === 200 });
}

function createPlan() {
  const body = JSON.stringify({
    week_budget_uah: 1200 + Math.floor(Math.random() * 800), // 1200–2000 грн
    daily_cal_target: 1800 + Math.floor(Math.random() * 400), // 1800–2200 ккал
    meals_per_day: 3,
    days: 7,
  });
  const res = http.post(`${API}/generate-plan`, body, {
    headers: JSON_HEADERS,
    tags: { name: "POST /generate-plan", op: "write" },
  });
  check(res, { "create 200": (r) => r.status === 200 });
  try {
    return res.json("plan_id");
  } catch (_) {
    return null;
  }
}

function randomId(plans, fallback) {
  return plans.length ? plans[Math.floor(Math.random() * plans.length)].id : fallback;
}

export default function () {
  // 1 запис
  const myId = createPlan();
  think();

  // 9 читань
  let plans = listPlans();
  think();
  if (myId) getPlan(myId);
  think();
  getIngredients();
  think();
  plans = listPlans();
  think();
  getPlan(randomId(plans, myId || 1));
  think();
  listPlans();
  think();
  if (myId) getPlan(myId);
  think();
  plans = listPlans();
  think();
  getPlan(randomId(plans, myId || 1));
  think();
}

// Підсумок у консоль і в JSON-файл (для docs/LOADTEST.md і docs/CACHE.md).
export function handleSummary(data) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19);
  return {
    stdout: textSummary(data, { indent: " ", enableColors: true }),
    [`loadtest/results/summary-cache-${CACHE}-${stamp}.json`]: JSON.stringify(data, null, 2),
  };
}
