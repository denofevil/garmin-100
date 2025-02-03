// Content Script

console.log("Started swimming");

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === 'changeColor') {
    document.body.style.backgroundColor = request.color;
    sendResponse({ status: 'Color changed' });
  }
});

// Function to replace the HTML fragment
function replaceTableRows() {
  const intervals = document.querySelectorAll("tr.table-row-parent.interval")
  console.log("Found " + intervals.length + " intervals");
  intervals.forEach(intervalElement => {
    const interval = intervalElement.getAttribute("class")?.match("interval-[^ ]*")
    if (interval) {
      const subIntervals = document.querySelectorAll("tr.table-row-child.length." + interval[0])
      console.log("Found " + subIntervals.length + " subIntervals for " + interval[0]);
      subIntervals.forEach(subIntervalElement =>{
        if (subIntervalElement.getAttribute("patched") != "true") {
          subIntervalElement.setAttribute("patched", "true")
          console.log("Patching complete")
        }
      })
    }
  });
}

// Call the function to replace rows initially
replaceTableRows();

// Set up a MutationObserver to watch for changes in the DOM
const observer = new MutationObserver((mutations) => {
  mutations.forEach((mutation) => {
    if (mutation.type === 'childList') {
      replaceTableRows(); // Call the replacement function on updates
    }
  });
});

// Start observing the document for changes
observer.observe(document.body, {
  childList: true,
  subtree: true
});
