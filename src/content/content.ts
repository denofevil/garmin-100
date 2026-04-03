// Content Script

console.log("Started swimming");

const HUNDRED_METERS_THRESHOLD = 99;
const LEGACY_PATCHED_ATTRIBUTE = "patched";
const CURRENT_PATCHED_ATTRIBUTE = "data-swim100-patched";

const COLUMN_INDEX = {
  interval: 1,
  lengths: 3,
  distance: 4,
  time: 5,
  cumulativeTime: 6,
  avgPace: 7,
  bestPace: 8,
  maxHr: 11,
  totalStrokes: 12,
  avgStrokes: 13,
} as const;

function parseInteger(value: string): number {
  const normalized = value.replace(/,/g, "").trim();
  if (!normalized || normalized === "--" || normalized === "💯") {
    return 0;
  }

  const parsed = Number.parseInt(normalized, 10);
  return Number.isNaN(parsed) ? 0 : parsed;
}

function timeToTenths(timeString: string): number {
  const normalized = timeString.trim();
  if (!normalized || normalized === "--") {
    return 0;
  }

  const [timePart, tenthsPart = "0"] = normalized.split(".");
  const timeSegments = timePart.split(":").map((segment) => segment.trim()).filter(Boolean);
  if (timeSegments.length === 0) {
    return 0;
  }

  let totalSeconds = 0;
  for (const segment of timeSegments) {
    const parsedSegment = Number.parseInt(segment, 10);
    if (Number.isNaN(parsedSegment)) {
      return 0;
    }

    totalSeconds = totalSeconds * 60 + parsedSegment;
  }

  const tenths = Number.parseInt(tenthsPart.charAt(0) || "0", 10);
  return totalSeconds * 10 + (Number.isNaN(tenths) ? 0 : tenths);
}

function tenthsToTime(tenths: number, printTenths: boolean = true): string {
  const totalSeconds = Math.floor(tenths / 10);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  const tenthsOfSecond = tenths % 10;
  return `${minutes}:${seconds.toString().padStart(2, "0")}${printTenths ? "." + tenthsOfSecond : ""}`;
}

function getCellText(row: HTMLTableRowElement, columnIndex: number): string {
  return row.cells.item(columnIndex)?.textContent?.trim() ?? "";
}

function setCellText(row: HTMLTableRowElement, columnIndex: number, value: string | number): void {
  const cell = row.cells.item(columnIndex);
  if (!cell) {
    return;
  }

  cell.textContent = String(value);
}

function copyCellHtml(
  targetRow: HTMLTableRowElement,
  targetColumnIndex: number,
  sourceRow: HTMLTableRowElement,
  sourceColumnIndex: number,
): void {
  const targetCell = targetRow.cells.item(targetColumnIndex);
  const sourceCell = sourceRow.cells.item(sourceColumnIndex);
  if (!targetCell || !sourceCell) {
    return;
  }

  targetCell.innerHTML = sourceCell.innerHTML;
}

function patchRowGroup(rows: HTMLTableRowElement[], patchedAttribute: string): void {
  if (rows.length === 0) {
    return;
  }

  const firstRow = rows[0];
  const lastRow = rows[rows.length - 1];
  const totalLengths = rows.reduce((total, row) => total + parseInteger(getCellText(row, COLUMN_INDEX.lengths)), 0);
  const totalTime = rows.reduce((total, row) => total + timeToTenths(getCellText(row, COLUMN_INDEX.time)), 0);
  const bestPace = rows.reduce((currentBest, row) => {
    const pace = timeToTenths(getCellText(row, COLUMN_INDEX.avgPace));
    return pace === 0 ? currentBest : Math.min(currentBest, pace);
  }, Number.MAX_SAFE_INTEGER);
  const maxHr = rows.reduce((currentMax, row) => Math.max(currentMax, parseInteger(getCellText(row, COLUMN_INDEX.maxHr))), 0);
  const totalStrokes = rows.reduce(
    (total, row) => total + parseInteger(getCellText(row, COLUMN_INDEX.totalStrokes)),
    0,
  );

  firstRow.setAttribute(patchedAttribute, "true");
  setCellText(firstRow, COLUMN_INDEX.lengths, totalLengths);
  setCellText(firstRow, COLUMN_INDEX.distance, "💯");
  setCellText(firstRow, COLUMN_INDEX.time, tenthsToTime(totalTime));
  copyCellHtml(firstRow, COLUMN_INDEX.cumulativeTime, lastRow, COLUMN_INDEX.cumulativeTime);
  setCellText(firstRow, COLUMN_INDEX.avgPace, tenthsToTime(Math.floor(totalTime / 10) * 10, false));
  if (bestPace !== Number.MAX_SAFE_INTEGER) {
    setCellText(firstRow, COLUMN_INDEX.bestPace, tenthsToTime(bestPace, false));
  }
  setCellText(firstRow, COLUMN_INDEX.maxHr, maxHr);
  setCellText(firstRow, COLUMN_INDEX.totalStrokes, totalStrokes);
  setCellText(firstRow, COLUMN_INDEX.avgStrokes, Math.floor(totalStrokes / rows.length));

  for (const row of rows.slice(1)) {
    row.remove();
  }
}

function replaceTableRows(): void {
  const intervals = document.querySelectorAll<HTMLTableRowElement>("tr.table-row-parent.interval");
  intervals.forEach((intervalElement) => {
    const intervalClass = intervalElement.className.match(/\binterval-[^\s]+\b/);
    if (!intervalClass) {
      return;
    }

    const subIntervals = Array.from(
      document.querySelectorAll<HTMLTableRowElement>(`tr.table-row-child.length.${intervalClass[0]}`),
    );

    let buffer: HTMLTableRowElement[] = [];
    let bufferDistance = 0;
    for (const subIntervalElement of subIntervals) {
      if (subIntervalElement.getAttribute(LEGACY_PATCHED_ATTRIBUTE) === "true") {
        continue;
      }

      buffer.push(subIntervalElement);
      bufferDistance += parseInteger(getCellText(subIntervalElement, COLUMN_INDEX.distance));

      if (bufferDistance >= HUNDRED_METERS_THRESHOLD) {
        patchRowGroup(buffer, LEGACY_PATCHED_ATTRIBUTE);
        buffer = [];
        bufferDistance = 0;
      }
    }
  });
}

function isTabSplitLengthRow(row: HTMLTableRowElement): boolean {
  const intervalLabel = getCellText(row, COLUMN_INDEX.interval);
  return /^\d+\.\d+$/.test(intervalLabel);
}

function replaceTabsRow(): void {
  const splitTables = document.querySelectorAll<HTMLTableElement>(
    '#tab-splits table[class*="IntervalsTable_table"], table[class*="IntervalsTable_table"]',
  );

  splitTables.forEach((table) => {
    const tableBody = table.tBodies.item(0);
    if (!tableBody) {
      return;
    }

    let buffer: HTMLTableRowElement[] = [];
    let bufferDistance = 0;
    let currentIntervalPrefix: string | null = null;

    for (const row of Array.from(tableBody.rows)) {
      if (row.getAttribute(CURRENT_PATCHED_ATTRIBUTE) === "true") {
        buffer = [];
        bufferDistance = 0;
        currentIntervalPrefix = null;
        continue;
      }

      if (!isTabSplitLengthRow(row)) {
        buffer = [];
        bufferDistance = 0;
        currentIntervalPrefix = null;
        continue;
      }

      const intervalPrefix = getCellText(row, COLUMN_INDEX.interval).split(".")[0];
      const rowDistance = parseInteger(getCellText(row, COLUMN_INDEX.distance));
      if (rowDistance === 0) {
        buffer = [];
        bufferDistance = 0;
        currentIntervalPrefix = null;
        continue;
      }

      if (currentIntervalPrefix !== null && currentIntervalPrefix !== intervalPrefix) {
        buffer = [];
        bufferDistance = 0;
      }

      currentIntervalPrefix = intervalPrefix;
      buffer.push(row);
      bufferDistance += rowDistance;

      if (bufferDistance >= HUNDRED_METERS_THRESHOLD) {
        patchRowGroup(buffer, CURRENT_PATCHED_ATTRIBUTE);
        buffer = [];
        bufferDistance = 0;
        currentIntervalPrefix = null;
      }
    }
  });
}

let patching = false;

function patchSplitTables(): void {
  patching = true;
  try {
    replaceTableRows();
    replaceTabsRow();
  } finally {
    patching = false;
  }
}

patchSplitTables();

const observer = new MutationObserver((mutations) => {
  for (const mutation of mutations) {
    if (!patching && mutation.type === "childList") {
      patchSplitTables();
      break;
    }
  }
});

if (document.body) {
  observer.observe(document.body, {
    childList: true,
    subtree: true,
  });
}
