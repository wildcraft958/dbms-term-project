// Constants
const SOLR_URL = '/solr/searchcore';
const ROWS_PER_PAGE = 10;

// DOM Elements
const searchForm = document.getElementById('search-form');
const searchInput = document.getElementById('search-input');
const searchButton = document.getElementById('search-button');
const suggestionsContainer = document.getElementById('suggestions');
const searchResults = document.getElementById('search-results');
const resultsStats = document.getElementById('results-stats');
const pagination = document.getElementById('pagination');
const categoryFacets = document.getElementById('category-facets')?.querySelector('.facet-items');
const tagsFacets = document.getElementById('tags-facets')?.querySelector('.facet-items');
const responseTimeElement = document.getElementById('response-time');
const searchMetrics = document.getElementById('search-metrics');
const responseTimeBadge = document.getElementById('response-time-badge');

// State
let currentQuery = '';
let currentPage = 0;
let selectedSuggestionIndex = -1;
let selectedFacets = {
    category: [],
    tags: []
};

document.addEventListener('DOMContentLoaded', () => {
    // Search input: suggestions + keyboard navigation
    if (searchInput) {
        searchInput.addEventListener('input', debounce(handleSuggestions, 300));
        searchInput.addEventListener('keydown', handleSuggestionKeyboard);
    }

    // Hide suggestions when clicking outside
    document.addEventListener('click', (e) => {
        if (suggestionsContainer && !suggestionsContainer.contains(e.target) && e.target !== searchInput) {
            suggestionsContainer.style.display = 'none';
            selectedSuggestionIndex = -1;
        }
    });

    // Handle search form submission
    if (searchForm) {
        searchForm.addEventListener('submit', (e) => {
            e.preventDefault();
            currentQuery = searchInput.value.trim();
            currentPage = 0;
            suggestionsContainer.style.display = 'none';

            if (!currentQuery) {
                showMessage('Please enter a search query.', 'info');
                return;
            }

            // Sanitize: limit query length
            if (currentQuery.length > 500) {
                showMessage('Query is too long. Please shorten your search.', 'warning');
                return;
            }

            performSearch();
        });
    }

    // Handle file upload form submission
    const uploadForm = document.getElementById('upload-document');
    if (uploadForm) {
        uploadForm.addEventListener('submit', function(event) {
            event.preventDefault();
            console.log("Starting the indexing");
            indexDocumentToSolr();
        });
    }

    // Handle file input change
    const fileInput = document.getElementById('file-upload');
    if (fileInput) {
        fileInput.addEventListener('change', function(e) {
            const fileName = e.target.files[0] ? e.target.files[0].name : '';
            const fileNameElement = document.getElementById('file-name');
            if (fileNameElement) {
                fileNameElement.textContent = fileName;
            }

            // Enable/disable the upload button based on file selection
            const uploadButton = document.getElementById('upload-button');
            if (uploadButton) {
                uploadButton.disabled = !fileName;
            }
        });
    }

    // Set up drag and drop functionality
    setupDragAndDrop();

    // Set up status observer
    setupStatusObserver();

    // Navbar scroll effect
    setupNavbarScroll();
});

function debounce(func, delay) {
    let timeout;
    return function() {
        const context = this;
        const args = arguments;
        clearTimeout(timeout);
        timeout = setTimeout(() => func.apply(context, args), delay);
    };
}

function showMessage(message, type = 'info') {
    if (!searchResults) return;
    const icon = type === 'warning' ? '⚠️' : type === 'info' ? '💡' : '❌';
    searchResults.innerHTML = `<div class="no-results">${icon} ${escapeHtml(message)}</div>`;
}

function setupNavbarScroll() {
    const navbar = document.getElementById('navbar');
    if (!navbar) return;
    window.addEventListener('scroll', () => {
        if (window.scrollY > 20) {
            navbar.style.background = 'rgba(15, 15, 26, 0.95)';
        } else {
            navbar.style.background = 'rgba(15, 15, 26, 0.8)';
        }
    });
}

function setupDragAndDrop() {
    const dropZone = document.getElementById('file-drop-zone');
    if (!dropZone) return;

    ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
        dropZone.addEventListener(eventName, preventDefaults, false);
    });

    ['dragenter', 'dragover'].forEach(eventName => {
        dropZone.addEventListener(eventName, () => dropZone.classList.add('drag-over'), false);
    });

    ['dragleave', 'drop'].forEach(eventName => {
        dropZone.addEventListener(eventName, () => dropZone.classList.remove('drag-over'), false);
    });

    dropZone.addEventListener('drop', handleDrop, false);
}

function preventDefaults(e) {
    e.preventDefault();
    e.stopPropagation();
}

function handleDrop(e) {
    const dt = e.dataTransfer;
    const files = dt.files;
    const fileInput = document.getElementById('file-upload');
    const fileNameElement = document.getElementById('file-name');
    const uploadButton = document.getElementById('upload-button');

    if (files.length && fileInput) {
        fileInput.files = files;
        if (fileNameElement) {
            fileNameElement.textContent = files[0].name;
        }
        if (uploadButton) {
            uploadButton.disabled = false;
        }
    }
}

function setupStatusObserver() {
    const statusElement = document.getElementById('upload-status');
    if (!statusElement) return;

    const observer = new MutationObserver(function(mutations) {
        mutations.forEach(function(mutation) {
            if (mutation.type === 'characterData' || mutation.type === 'childList') {
                const content = statusElement.textContent.toLowerCase();

                statusElement.classList.remove('status-processing', 'status-success', 'status-error', 'loading');

                if (content.includes('processing') || content.includes('uploading')) {
                    statusElement.classList.add('status-processing', 'loading');
                } else if (content.includes('success')) {
                    statusElement.classList.add('status-success');
                } else if (content.includes('error') || content.includes('failed')) {
                    statusElement.classList.add('status-error');
                }
            }
        });
    });

    observer.observe(statusElement, { childList: true, characterData: true, subtree: true });
}

function indexDocumentToSolr() {
    const form = document.getElementById('upload-document');
    const fileInput = form.querySelector('input[type="file"]');

    if (!fileInput || !fileInput.files || fileInput.files.length === 0) {
        alert("Please select a file to upload");
        return false;
    }

    const file = fileInput.files[0];
    const fileName = file.name;

    const statusElement = document.getElementById('upload-status');
    if (statusElement) {
        statusElement.textContent = "Processing and indexing document...";
    }

    if (file.type === 'application/pdf') {
        processPdfFile(file, fileName, SOLR_URL, statusElement);
    } else {
        processTextFile(file, fileName, SOLR_URL, statusElement);
    }

    return false;
}

function processPdfFile(file, fileName, solr_url, statusElement) {
    const fileReader = new FileReader();

    fileReader.onload = function(event) {
        const typedArray = new Uint8Array(event.target.result);

        pdfjsLib.getDocument(typedArray).promise.then(function(pdf) {
            console.log(`PDF loaded: ${fileName}, pages: ${pdf.numPages}`);

            const pagesPromises = [];

            for (let i = 1; i <= pdf.numPages; i++) {
                pagesPromises.push(getPageTextWithParagraphs(pdf, i));
            }

            Promise.all(pagesPromises).then(function(pagesData) {
                const indexPromises = [];

                pagesData.forEach((pageData, pageIndex) => {
                    const pageNumber = pageIndex + 1;

                    pageData.paragraphs.forEach((paragraph, paraIndex) => {
                        if (paragraph.trim().length > 0) {
                            const paraId = `${fileName}_page${pageNumber}_para${paraIndex + 1}`;
                            const doc = {
                                'id': paraId,
                                'content': paragraph,
                                'paragraph_text': paragraph,
                                'file_name': fileName,
                                'page_number': pageNumber,
                                'paragraph_number': paraIndex + 1,
                                'page_count': pdf.numPages,
                                'title': `${paragraph} - Page ${pageNumber}`,
                                'last_modified': new Date().toISOString()
                            };

                            console.log(doc);

                            indexPromises.push(
                                indexSingleDocToSolr(doc, solr_url)
                                .catch(error => {
                                    console.error(`Error indexing paragraph ${paraIndex + 1} of page ${pageNumber}:`, error);
                                    return false;
                                })
                            );
                        }
                    });
                });

                Promise.all(indexPromises).then(results => {
                    const successCount = results.filter(Boolean).length;
                    console.log(`Indexed ${successCount} paragraphs from PDF`);

                    fetch(`${solr_url}/update?commit=true`, {
                        method: 'POST',
                        headers: {
                            'Content-Type': 'application/json'
                        },
                        body: '{}'
                    })
                    .then(() => {
                        if (statusElement) {
                            statusElement.textContent = `Document successfully indexed with ${successCount} paragraphs!`;
                        }
                        alert(`Document has been successfully indexed with ${successCount} paragraphs!`);
                    })
                    .catch(error => {
                        console.error("Error committing to Solr:", error);
                        if (statusElement) {
                            statusElement.textContent = "Error finalizing indexing.";
                        }
                    });
                });
            });
        }).catch(function(error) {
            console.error(`Error processing PDF: ${error}`);
            if (statusElement) {
                statusElement.textContent = "Error processing PDF.";
            }
            alert(`Failed to process PDF: ${error.message}`);
        });
    };

    fileReader.onerror = function() {
        console.error(`Failed to read file: ${fileReader.error}`);
        if (statusElement) {
            statusElement.textContent = "Error reading file.";
        }
        alert("Failed to read file.");
    };

    fileReader.readAsArrayBuffer(file);
}

function getPageTextWithParagraphs(pdf, pageNumber) {
    return pdf.getPage(pageNumber).then(function(page) {
        return page.getTextContent().then(function(textContent) {
            const pageText = textContent.items.map(item => item.str).join(' ');
            const paragraphs = splitIntoParagraphs(pageText);

            return {
                pageNumber: pageNumber,
                text: pageText,
                paragraphs: paragraphs
            };
        });
    });
}

function splitIntoParagraphs(text) {
    text = text.replace(/\s+/g, ' ');
    const roughParagraphs = text.split(/\n\s*\n|\.\s+(?=[A-Z])/);
    return roughParagraphs
        .map(p => p.trim())
        .filter(p => p.length > 0);
}

function processTextFile(file, fileName, solr_url, statusElement) {
    const reader = new FileReader();

    reader.onload = function(event) {
        const textContent = event.target.result;
        const paragraphs = splitIntoParagraphs(textContent);
        const indexPromises = [];

        paragraphs.forEach((paragraph, paraIndex) => {
            if (paragraph.trim().length > 0) {
                const paraId = `${fileName}_para${paraIndex + 1}`;
                const doc = {
                    'id': paraId,
                    'content': paragraph,
                    'paragraph_text': paragraph,
                    'file_name': fileName,
                    'paragraph_number': paraIndex + 1,
                    'title': paragraph,
                    'last_modified': new Date().toISOString()
                };

                console.log(`The para is :${doc}`);
                indexPromises.push(
                    indexSingleDocToSolr(doc, solr_url)
                    .catch(error => {
                        console.error(`Error indexing paragraph ${paraIndex + 1}:`, error);
                        return false;
                    })
                );
            }
        });

        Promise.all(indexPromises).then(results => {
            const successCount = results.filter(Boolean).length;
            console.log(`Indexed ${successCount} paragraphs from text file`);

            fetch(`${solr_url}/update?commit=true`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: '{}'
            })
            .then(() => {
                if (statusElement) {
                    statusElement.textContent = `Document successfully indexed with ${successCount} paragraphs!`;
                }
                alert(`Document has been successfully indexed with ${successCount} paragraphs!`);
            })
            .catch(error => {
                console.error("Error committing to Solr:", error);
                if (statusElement) {
                    statusElement.textContent = "Error finalizing indexing.";
                }
            });
        });
    };

    reader.onerror = function() {
        console.error(`Failed to read file: ${reader.error}`);
        if (statusElement) {
            statusElement.textContent = "Error reading file.";
        }
        alert("Failed to read file.");
    };

    reader.readAsText(file);
}

function indexSingleDocToSolr(doc, solr_url) {
    return fetch(`${solr_url}/update/json/docs?commitWithin=1000`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify(doc)
    })
    .then(response => {
        if (!response.ok) {
            return response.text().then(text => {
                throw new Error(`HTTP error! Status: ${response.status}, Details: ${text}`);
            });
        }
        return true;
    });
}

// Legacy function for backward compatibility
function indexDocToSolr(doc, fileName, solr_url, statusElement) {
    console.log("Sending document to Solr:", doc);

    console.log(`${solr_url}/update?commit=true`);
    fetch(`${solr_url}/update?commit=true`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify([doc])
    })
    .then(response => {
        if (!response.ok) {
            return response.text().then(text => {
                throw new Error(`HTTP error! Status: ${response.status}, Details: ${text}`);
            });
        }
        return response.text();
    })
    .then(data => {
        console.log(`Indexed ${fileName}: Success`, data);
        if (statusElement) {
            statusElement.textContent = "Document successfully indexed!";
        }
        alert("Document has been successfully indexed!");
    })
    .catch(error => {
        console.error(`Error indexing ${fileName}:`, error);
        if (statusElement) {
            statusElement.textContent = "Error indexing document. See console for details.";
        }
        alert("Failed to index document. Error: " + error.message);
    });
}

async function handleSuggestions() {
    const query = searchInput.value.trim();
    if (query.length < 2) {
        suggestionsContainer.style.display = 'none';
        selectedSuggestionIndex = -1;
        return;
    }

    try {
        console.log(`${SOLR_URL}/suggest?q=${encodeURIComponent(query)}&wt=json`);
        const response = await fetch(`${SOLR_URL}/suggest?q=${encodeURIComponent(query)}&wt=json`);
        const data = await response.json();

        const suggestions = data.suggest?.mySuggester?.[query]?.suggestions || [];

        console.log(suggestions);

        if (suggestions.length > 0) {
            renderSuggestions(suggestions);
            suggestionsContainer.style.display = 'block';
        } else {
            suggestionsContainer.style.display = 'none';
        }
    } catch (error) {
        console.error('Error fetching suggestions:', error);
        suggestionsContainer.style.display = 'none';
    }
}

function handleSuggestionKeyboard(e) {
    const items = suggestionsContainer.querySelectorAll('.suggestion-container');
    if (!items.length || suggestionsContainer.style.display === 'none') {
        if (e.key === 'Escape') {
            suggestionsContainer.style.display = 'none';
        }
        return;
    }

    switch (e.key) {
        case 'ArrowDown':
            e.preventDefault();
            selectedSuggestionIndex = Math.min(selectedSuggestionIndex + 1, items.length - 1);
            updateSuggestionHighlight(items);
            break;
        case 'ArrowUp':
            e.preventDefault();
            selectedSuggestionIndex = Math.max(selectedSuggestionIndex - 1, -1);
            updateSuggestionHighlight(items);
            break;
        case 'Enter':
            if (selectedSuggestionIndex >= 0 && selectedSuggestionIndex < items.length) {
                e.preventDefault();
                items[selectedSuggestionIndex].click();
            }
            break;
        case 'Escape':
            suggestionsContainer.style.display = 'none';
            selectedSuggestionIndex = -1;
            break;
    }
}

function updateSuggestionHighlight(items) {
    items.forEach((item, index) => {
        item.classList.toggle('selected', index === selectedSuggestionIndex);
    });

    if (selectedSuggestionIndex >= 0 && items[selectedSuggestionIndex]) {
        searchInput.value = items[selectedSuggestionIndex].textContent;
    }
}

function renderSuggestions(suggestions) {
    suggestionsContainer.innerHTML = '';
    selectedSuggestionIndex = -1;

    suggestions.forEach(suggestion => {
        const suggestionItem = document.createElement('div');
        suggestionItem.className = 'suggestion-container';
        suggestionItem.textContent = suggestion.term;

        suggestionItem.addEventListener('click', () => {
            searchInput.value = suggestion.term;
            suggestionsContainer.style.display = 'none';
            selectedSuggestionIndex = -1;
            currentQuery = suggestion.term;
            currentPage = 0;
            performSearch();
        });

        suggestionsContainer.appendChild(suggestionItem);
    });
}

async function performSearch() {
    // Display loading skeleton
    searchResults.innerHTML = `
        <div class="file-result" style="opacity:1;transform:none;">
            <div class="skeleton" style="height:20px;width:40%;margin-bottom:16px;"></div>
            <div class="skeleton" style="height:14px;width:100%;margin-bottom:8px;"></div>
            <div class="skeleton" style="height:14px;width:90%;margin-bottom:8px;"></div>
            <div class="skeleton" style="height:14px;width:75%;"></div>
        </div>
        <div class="file-result" style="opacity:1;transform:none;">
            <div class="skeleton" style="height:20px;width:35%;margin-bottom:16px;"></div>
            <div class="skeleton" style="height:14px;width:100%;margin-bottom:8px;"></div>
            <div class="skeleton" style="height:14px;width:85%;"></div>
        </div>
    `;
    resultsStats.innerHTML = '';

    // Construct the Solr query URL with improved highlighting and paragraph-level searching.
    // currentPage is a zero-based page index; Solr's `start` is a row offset.
    const startOffset = currentPage * ROWS_PER_PAGE;
    let url = `${SOLR_URL}/select?q=${encodeURIComponent(currentQuery)}&start=${startOffset}&rows=${ROWS_PER_PAGE}`;

    // Enhanced highlighting for paragraphs
    url += '&hl=on&hl.fl=content,paragraph_text&hl.snippets=3&hl.fragsize=150';
    url += '&hl.simple.pre=<mark>&hl.simple.post=</mark>';
    url += '&hl.maxAnalyzedChars=251000';

    // Add faceting
    url += '&facet=on&facet.field=file_name&facet.mincount=1&facet.limit=20';

    // Group results by file name to consolidate related paragraphs
    url += '&group=true&group.field=file_name&group.limit=10';

    // Add JSON response format
    url += '&wt=json';

    // Measure response time
    const startTime = performance.now();

    try {
        console.log(`Fetching ${url}`);
        const response = await fetch(url);
        const data = await response.json();
        console.log(data);

        // Calculate response time
        const endTime = performance.now();
        const responseTime = Math.round(endTime - startTime);

        // Update response time badge
        if (responseTimeElement) {
            responseTimeElement.textContent = responseTime;
        }
        if (searchMetrics) {
            searchMetrics.classList.add('show');
        }
        if (responseTimeBadge) {
            responseTimeBadge.classList.remove('slow', 'error');
            if (responseTime > 1000) {
                responseTimeBadge.classList.add('error');
            } else if (responseTime > 300) {
                responseTimeBadge.classList.add('slow');
            }
        }

        // Render results with improved highlighting
        renderEnhancedResults(data);

        // Render facets if they exist
        if (data.facet_counts && data.facet_counts.facet_fields) {
            renderFacets(data.facet_counts.facet_fields);
        }

        // Render pagination based on total results
        if (data.grouped && data.grouped.file_name) {
            renderPagination(data.grouped.file_name.matches);
        } else if (data.response) {
            renderPagination(data.response.numFound);
        }
    } catch (error) {
        console.error('Error performing search:', error);
        searchResults.innerHTML = '<div class="error"> An error occurred while searching. Please check that Solr is running and try again.</div>';
    }
}

function renderEnhancedResults(data) {
    if (data.grouped && data.grouped.file_name) {
        renderGroupedResults(data);
    } else {
        renderStandardResults(data);
    }
}

function renderGroupedResults(data) {
    const { grouped, highlighting } = data;
    const groups = grouped.file_name.groups;
    const totalMatches = grouped.file_name.matches;

    if (resultsStats) {
        resultsStats.innerHTML = `Found <strong>${totalMatches}</strong> results for <strong>"${escapeHtml(currentQuery)}"</strong>`;
    }

    if (groups.length === 0) {
        searchResults.innerHTML = '<div class="no-results">No results found. Try a different search query.</div>';
        return;
    }

    searchResults.innerHTML = '';

    groups.forEach(group => {
        const fileDiv = document.createElement('div');
        fileDiv.className = 'file-result';

        const fileName = group.groupValue;

        const fileHeader = document.createElement('h3');
        fileHeader.className = 'file-name';
        fileHeader.textContent = fileName;
        fileDiv.appendChild(fileHeader);

        const docs = group.doclist.docs;

        docs.sort((a, b) => {
            if ((a.page_number || 0) !== (b.page_number || 0)) {
                return (a.page_number || 0) - (b.page_number || 0);
            }
            return (a.paragraph_number || 0) - (b.paragraph_number || 0);
        });

        const pageHeaderCreated = {};

        docs.forEach(doc => {
            if (doc.page_number && !pageHeaderCreated[doc.page_number]) {
                const pageHeader = document.createElement('h4');
                pageHeader.className = 'page-header';
                pageHeader.textContent = `Page ${doc.page_number}`;
                fileDiv.appendChild(pageHeader);
                pageHeaderCreated[doc.page_number] = true;
            }

            const snippetDiv = document.createElement('div');
            snippetDiv.className = 'result-snippet';

            const docHighlights = highlighting[doc.id];
            let highlightedContent = '';

            if (docHighlights && docHighlights.paragraph_text && docHighlights.paragraph_text.length > 0) {
                highlightedContent = docHighlights.paragraph_text.join('... ');
            } else if (docHighlights && docHighlights.content && docHighlights.content.length > 0) {
                highlightedContent = docHighlights.content.join('... ');
            } else {
                highlightedContent = doc.paragraph_text || doc.content || '';
                if (Array.isArray(highlightedContent)) {
                    highlightedContent = highlightedContent.join(' ');
                }
                if (highlightedContent) {
                    const regex = new RegExp('(' + escapeRegExp(currentQuery) + ')', 'gi');
                    highlightedContent = highlightedContent.replace(regex, '<mark>$1</mark>');
                }
            }

            if (doc.paragraph_number) {
                const paraNum = document.createElement('span');
                paraNum.className = 'paragraph-number';
                paraNum.textContent = `¶${doc.paragraph_number}: `;
                snippetDiv.appendChild(paraNum);
            }

            const contentSpan = document.createElement('span');
            contentSpan.className = 'snippet-content';
            contentSpan.innerHTML = highlightedContent;
            snippetDiv.appendChild(contentSpan);

            fileDiv.appendChild(snippetDiv);
        });

        searchResults.appendChild(fileDiv);
    });
}

function renderStandardResults(data) {
    const { response, highlighting } = data;
    const { numFound, docs } = response;

    if (resultsStats) {
        resultsStats.innerHTML = `Found <strong>${numFound}</strong> results for <strong>"${escapeHtml(currentQuery)}"</strong>`;
    }

    if (docs.length === 0) {
        searchResults.innerHTML = '<div class="no-results"> No results found. Try a different search query.</div>';
        return;
    }

    searchResults.innerHTML = '';

    const fileResults = {};
    docs.forEach(doc => {
        const fileName = doc.file_name || doc.id;
        if (!fileResults[fileName]) {
            fileResults[fileName] = [];
        }
        fileResults[fileName].push(doc);
    });

    Object.keys(fileResults).forEach(fileName => {
        const fileDiv = document.createElement('div');
        fileDiv.className = 'file-result';

        const fileHeader = document.createElement('h3');
        fileHeader.className = 'file-name';
        fileHeader.textContent = fileName;
        fileDiv.appendChild(fileHeader);

        fileResults[fileName].sort((a, b) => {
            if ((a.page_number || 0) !== (b.page_number || 0)) {
                return (a.page_number || 0) - (b.page_number || 0);
            }
            return (a.paragraph_number || 0) - (b.paragraph_number || 0);
        });

        const pageHeaderCreated = {};

        fileResults[fileName].forEach(doc => {
            if (doc.page_number && !pageHeaderCreated[doc.page_number]) {
                const pageHeader = document.createElement('h4');
                pageHeader.className = 'page-header';
                pageHeader.textContent = `Page ${doc.page_number}`;
                fileDiv.appendChild(pageHeader);
                pageHeaderCreated[doc.page_number] = true;
            }

            const snippetDiv = document.createElement('div');
            snippetDiv.className = 'result-snippet';

            const docHighlights = highlighting[doc.id];
            let highlightedContent = '';

            if (docHighlights && docHighlights.paragraph_text && docHighlights.paragraph_text.length > 0) {
                highlightedContent = docHighlights.paragraph_text.join('... ');
            } else if (docHighlights && docHighlights.content && docHighlights.content.length > 0) {
                highlightedContent = docHighlights.content.join('... ');
            } else {
                highlightedContent = doc.paragraph_text || doc.content || '';
                if (Array.isArray(highlightedContent)) {
                    highlightedContent = highlightedContent.join(' ');
                }
                if (highlightedContent) {
                    const regex = new RegExp('(' + escapeRegExp(currentQuery) + ')', 'gi');
                    highlightedContent = highlightedContent.replace(regex, '<mark>$1</mark>');
                }
            }

            if (doc.paragraph_number) {
                const paraNum = document.createElement('span');
                paraNum.className = 'paragraph-number';
                paraNum.textContent = `¶${doc.paragraph_number}: `;
                snippetDiv.appendChild(paraNum);
            }

            const contentSpan = document.createElement('span');
            contentSpan.className = 'snippet-content';
            contentSpan.innerHTML = highlightedContent;
            snippetDiv.appendChild(contentSpan);

            fileDiv.appendChild(snippetDiv);
        });

        searchResults.appendChild(fileDiv);
    });
}

function renderFacets(facetFields) {
    if (categoryFacets && facetFields.file_name) {
        renderFacetGroup(facetFields.file_name, categoryFacets, 'file_name');
    }
}

function renderFacetGroup(facetData, container, facetName) {
    container.innerHTML = '';

    const facets = [];
    for (let i = 0; i < facetData.length; i += 2) {
        facets.push({
            value: facetData[i].slice(0, 10),
            count: facetData[i + 1]
        });
    }

    facets.forEach(facet => {
        const facetItem = document.createElement('div');
        facetItem.className = 'facet-item';

        const label = document.createElement('label');

        const checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.value = facet.value.slice(0, 10);
        checkbox.checked = selectedFacets[facetName] && selectedFacets[facetName].includes(facet.value);

        checkbox.addEventListener('change', () => {
            if (!selectedFacets[facetName]) {
                selectedFacets[facetName] = [];
            }

            if (checkbox.checked) {
                selectedFacets[facetName].push(facet.value);
            } else {
                selectedFacets[facetName] = selectedFacets[facetName].filter(v => v !== facet.value);
            }

            currentPage = 0;
            performSearch();
        });
        label.appendChild(checkbox);
        label.appendChild(document.createTextNode(` ${facet.value}`));

        const count = document.createElement('span');
        count.className = 'facet-count';
        count.textContent = `(${facet.count})`;
        label.appendChild(count);

        facetItem.appendChild(label);
        container.appendChild(facetItem);
    });
}

function renderPagination(totalResults) {
    pagination.innerHTML = '';

    const totalPages = Math.ceil(totalResults / ROWS_PER_PAGE);

    if (totalPages <= 1) {
        return;
    }

    // Previous button
    if (currentPage > 0) {
        const prevButton = createPaginationButton('← Prev', () => {
            currentPage--;
            performSearch();
            window.scrollTo(0, 0);
        });
        pagination.appendChild(prevButton);
    }

    // Page numbers
    const maxPageButtons = 5;
    let startPage = Math.max(0, currentPage - Math.floor(maxPageButtons / 2));
    let endPage = Math.min(totalPages - 1, startPage + maxPageButtons - 1);

    if (endPage - startPage < maxPageButtons - 1) {
        startPage = Math.max(0, endPage - maxPageButtons + 1);
    }

    for (let i = startPage; i <= endPage; i++) {
        const pageButton = createPaginationButton(i + 1, () => {
            currentPage = i;
            performSearch();
            window.scrollTo(0, 0);
        }, i === currentPage);

        pagination.appendChild(pageButton);
    }

    // Next button
    if (currentPage < totalPages - 1) {
        const nextButton = createPaginationButton('Next →', () => {
            currentPage++;
            performSearch();
            window.scrollTo(0, 0);
        });
        pagination.appendChild(nextButton);
    }
}

function createPaginationButton(text, onClick, isActive = false) {
    const button = document.createElement('button');
    button.className = 'pagination-button';
    if (isActive) {
        button.classList.add('active');
    }
    button.textContent = text;
    button.addEventListener('click', onClick);
    return button;
}

function truncateText(text, maxLength) {
    if (text.length <= maxLength) {
        return text;
    }
    return text.substring(0, maxLength) + '...';
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function escapeRegExp(string) {
    return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}