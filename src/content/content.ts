// Content Script

console.log("Started swimming");

function convertTimeToTenths(timeString: string): number {
    const [minutes, secondsTenths] = timeString.split(':');
    const [seconds, tenths] = secondsTenths.split('.');
    return (parseInt(minutes) * 60 + parseInt(seconds)) * 10 + (tenths ? parseInt(tenths) : 0);
}

class SubIntervalHolder {
  length: Number
  time: Number
  style: String
  element: Element
  constructor(length: Number, time: Number, style: String, element: Element) {
    this.length = length;
    this.time = time;
    this.style = style;
    this.element = element;
  }
};

let patching = false;

// Function to replace the HTML fragment
function replaceTableRows() {
  patching = true;
  const intervals = document.querySelectorAll("tr.table-row-parent.interval")
  console.log("Found " + intervals.length + " intervals");
  intervals.forEach(intervalElement => {
    const interval = intervalElement.getAttribute("class")?.match("interval-[^ ]*")
    if (interval) {
      const subIntervals = document.querySelectorAll("tr.table-row-child.length." + interval[0])
      console.log("Found " + subIntervals.length + " subIntervals for " + interval[0]);

      let bufferLength = 0
      let buffer = new Array<SubIntervalHolder>()
      subIntervals.forEach(subIntervalElement => {
        if (subIntervalElement.getAttribute("patched") != "true") {
          subIntervalElement.setAttribute("patched", "true")
          const style = subIntervalElement.children[2].innerHTML.trim()
          const length = parseInt(subIntervalElement.children[4].innerHTML.trim())
          const time = subIntervalElement.children[5].innerHTML.trim()
          buffer.push(new SubIntervalHolder(length, time, style, subIntervalElement))
          bufferLength += length;
          if (bufferLength == 100) {
            buffer[0].element.children[4].outerHTML = "<td class> 💯 </td>"
            buffer[0].element.children[6].outerHTML = buffer[3].element.children[6].outerHTML
            buffer[1].element.remove()
            buffer[2].element.remove()
            buffer[3].element.remove()
            buffer = new Array<SubIntervalHolder>()
            bufferLength = 0
          }
//          console.log("Style: " + style + ", length: " + length)

//          subIntervalElement.children[6] // cumulative time
//          subIntervalElement.children[7] // pace
//          subIntervalElement.children[8] // best pace
//          subIntervalElement.children[9] // avg swolf
//          subIntervalElement.children[10] // avg HR
//          subIntervalElement.children[11] // max HR
//          subIntervalElement.children[12] // tot strokes
//          subIntervalElement.children[13] // avg strokes - not present, calculate
//          subIntervalElement.children[14] // calories - not present, calculate
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
