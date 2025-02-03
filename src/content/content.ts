// Content Script

console.log('Content script loaded');

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === 'changeColor') {
    document.body.style.backgroundColor = request.color;
    sendResponse({ status: 'Color changed' });
  }
});
