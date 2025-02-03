// Content Script

console.log("Started swimming");

function timeToTenths(timeString: string): number {
    const [minutes, secondsTenths] = timeString.split(':');
    const [seconds, tenths] = secondsTenths.split('.');
    return (parseInt(minutes) * 60 + parseInt(seconds)) * 10 + (tenths ? parseInt(tenths) : 0);
}

function tenthsToTime(tenths: number, printTenths: boolean = true): string {
    const totalSeconds = Math.floor(tenths / 10);
    const minutes = Math.floor(totalSeconds / 60);
    const seconds = totalSeconds % 60;
    const tenthsOfSecond = tenths % 10;
    return `${minutes}:${seconds.toString().padStart(2, '0')}${printTenths ? "." + tenthsOfSecond : ""}`;
}

class SubIntervalHolder {
  length: number
  lanes: number
  time: number
  pace: number
  maxHr: number
  strokes: number
  style: String
  element: Element
  constructor(length: number, lanes:number, time: number, pace: number, maxHr: number, strokes: number, style: String, element: Element) {
    this.length = length;
    this.lanes = lanes;
    this.time = time;
    this.pace = pace;
    this.maxHr = maxHr;
    this.strokes = strokes;
    this.style = style;
    this.element = element;
  }
};

let patching = false;

// Function to replace the HTML fragment
function replaceTableRows() {
  patching = true;
  const intervals = document.querySelectorAll("tr.table-row-parent.interval")
//  console.log("Found " + intervals.length + " intervals");
  intervals.forEach(intervalElement => {
    const interval = intervalElement.getAttribute("class")?.match("interval-[^ ]*")
    if (interval) {
      const subIntervals = document.querySelectorAll("tr.table-row-child.length." + interval[0])
//      console.log("Found " + subIntervals.length + " subIntervals for " + interval[0]);

      let bufferLength = 0
      let buffer = new Array<SubIntervalHolder>()
      subIntervals.forEach(subIntervalElement => {
        if (subIntervalElement.getAttribute("patched") != "true") {
          subIntervalElement.setAttribute("patched", "true")
          const style = subIntervalElement.children[2].innerHTML.trim()
          const lanes = parseInt(subIntervalElement.children[3].innerHTML.trim())
          const length = parseInt(subIntervalElement.children[4].innerHTML.trim())
          const time = timeToTenths(subIntervalElement.children[5].innerHTML.trim())
          const pace = timeToTenths(subIntervalElement.children[7].innerHTML.trim())
          const maxHr = parseInt(subIntervalElement.children[11].innerHTML.trim())
          const strokes = parseInt(subIntervalElement.children[12].innerHTML.trim())
          buffer.push(new SubIntervalHolder(length, lanes, time, pace, maxHr, strokes, style, subIntervalElement))
          bufferLength += length;
          if (bufferLength >= 99) {
            //lanes
            const lanes = buffer.reduce((total, element) => {
              return total + element.lanes;
            }, 0);
            buffer[0].element.children[3].outerHTML = "<td class> " + lanes + " </td>";

            // length
            buffer[0].element.children[4].outerHTML = "<td class> 💯 </td>";

            // time
            const time = buffer.reduce((total, element) => {
              return total + element.time;
            }, 0);
            buffer[0].element.children[5].outerHTML = "<td class> " + tenthsToTime(time) + " </td>";

            // cumulative time
            buffer[0].element.children[6].outerHTML = buffer[buffer.length - 1].element.children[6].outerHTML;

            // pace
            buffer[0].element.children[7].outerHTML = "<td class> " + tenthsToTime(Math.floor(time / 10) * 10, false) + " </td>";

            // best pace
            const bestPace = buffer.reduce((total, element) => {
              return Math.min(total, element.pace);
            }, 100000000);
            buffer[0].element.children[8].outerHTML = "<td class> " + tenthsToTime(bestPace, false) + " </td>";
            //          subIntervalElement.children[9] // avg swolf
            //          subIntervalElement.children[10] // avg HR

            // max HR
            const maxHr = buffer.reduce((total, element) => {
              return Math.max(total, element.maxHr);
            }, 0);
            buffer[0].element.children[11].outerHTML = "<td class> " + maxHr + " </td>";

            // tot strokes
            const strokes = buffer.reduce((total, element) => {
              return total + element.strokes;
            }, 0);
            buffer[0].element.children[12].outerHTML = "<td class> " + strokes + " </td>";
            // avg strokes
            buffer[0].element.children[13].outerHTML = "<td class> " + Math.floor(strokes / buffer.length) + " </td>";

            for (let i = 1; i < buffer.length; i++) {
              buffer[i].element.remove()
            }
            buffer = new Array<SubIntervalHolder>()
            bufferLength = 0
          }
        }
      })
    }
  });
  patching = false;
}

// Call the function to replace rows initially
replaceTableRows();

// Set up a MutationObserver to watch for changes in the DOM
const observer = new MutationObserver((mutations) => {
  mutations.forEach((mutation) => {
    if (!patching && mutation.type === 'childList') {
      replaceTableRows(); // Call the replacement function on updates
    }
  });
});

// Start observing the document for changes
observer.observe(document.body, {
  childList: true,
  subtree: true
});
