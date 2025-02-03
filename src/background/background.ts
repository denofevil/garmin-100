// Background script for the Chrome extension

// Listen for installation event
chrome.runtime.onInstalled.addListener(() => {
  console.log('Extension installed successfully!');
});

// Listen for messages from other parts of the extension (e.g., popup or content scripts)
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  console.log('Received message:', message);

  // Example: Change tab's background color based on message action
  if (message.action === 'changeTabColor' && message.color) {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs[0] && tabs[0].id) {
        chrome.scripting.executeScript({
          target: { tabId: tabs[0].id },
          func: (color) => {
            document.body.style.backgroundColor = color;
          },
          args: [message.color],
        });
        sendResponse({ status: 'Color change executed' });
      } else {
        sendResponse({ status: 'Error: No active tab found' });
      }
    });

    // Mark as async response
    return true;
  }

  // Respond to any other messages
  sendResponse({ status: 'Unknown action' });
});

// Other background listeners or tasks can go here
