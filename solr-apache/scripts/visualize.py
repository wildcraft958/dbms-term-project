#!/usr/bin/env python3
"""
This script visualizes benchmark results from siege-benchmark.sh outputs.
"""

import json
import argparse
import os
import sys
import matplotlib.pyplot as plt
import matplotlib as mpl
from datetime import datetime

def parse_arguments():
    parser = argparse.ArgumentParser(description='Visualize Solr benchmark results')
    parser.add_argument('input_file', help='JSON file with benchmark results')
    parser.add_argument('--output-dir', default='./visualizations',
                      help='Directory to save visualization output (default: ./visualizations)')
    parser.add_argument('--format', choices=['png', 'svg', 'pdf'], default='png',
                      help='Output file format (default: png)')
    parser.add_argument('--theme', choices=['light', 'dark'], default='light',
                      help='Visualization theme (default: light)')
    return parser.parse_args()

def load_benchmark_data(file_path):
    """Load benchmark data from JSON file"""
    try:
        with open(file_path, 'r') as f:
            data = json.load(f)
        return data
    except (json.JSONDecodeError, FileNotFoundError) as e:
        print(f"Error loading benchmark data: {e}")
        sys.exit(1)

def setup_theme(theme):
    """Configure matplotlib theme"""
    if theme == 'dark':
        plt.style.use('dark_background')
        text_color = 'white'
    else:
        plt.style.use('default')
        text_color = 'black'
    return text_color

def create_visualizations(data, output_dir, file_format, text_color):
    """Generate various visualizations from the benchmark data"""
    # Create output directory if it doesn't exist
    os.makedirs(output_dir, exist_ok=True)
    
    # Extract benchmark data
    results = data['results']
    
    # Get concurrent users as x-axis values
    concurrent_users = [r['concurrent_users'] for r in results]
    
    # Create timestamp for filenames
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    
    # 1. Response Time vs Concurrent Users
    plt.figure(figsize=(10, 6))
    plt.plot(concurrent_users, [r['response_time'] for r in results], 'o-', linewidth=2)
    plt.title('Response Time vs Concurrent Users', fontsize=16, color=text_color)
    plt.xlabel('Concurrent Users', fontsize=14, color=text_color)
    plt.ylabel('Response Time (seconds)', fontsize=14, color=text_color)
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/response_time_{timestamp}.{file_format}")
    plt.close()
    
    # 2. Transaction Rate vs Concurrent Users
    plt.figure(figsize=(10, 6))
    plt.plot(concurrent_users, [r['transaction_rate'] for r in results], 'o-', color='green', linewidth=2)
    plt.title('Transaction Rate vs Concurrent Users', fontsize=16, color=text_color)
    plt.xlabel('Concurrent Users', fontsize=14, color=text_color)
    plt.ylabel('Transactions per second', fontsize=14, color=text_color)
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/transaction_rate_{timestamp}.{file_format}")
    plt.close()
    
    # 3. Availability vs Concurrent Users
    plt.figure(figsize=(10, 6))
    plt.plot(concurrent_users, [r['availability'] for r in results], 'o-', color='purple', linewidth=2)
    plt.title('Availability vs Concurrent Users', fontsize=16, color=text_color)
    plt.xlabel('Concurrent Users', fontsize=14, color=text_color)
    plt.ylabel('Availability (%)', fontsize=14, color=text_color)
    plt.grid(True, alpha=0.3)
    plt.ylim(0, 102)  # Give a little room above 100%
    plt.tight_layout()
    plt.savefig(f"{output_dir}/availability_{timestamp}.{file_format}")
    plt.close()
    
    # 4. Success vs Failure
    plt.figure(figsize=(10, 6))
    successful = [r['successful_transactions'] for r in results]
    failed = [r['failed_transactions'] for r in results]
    
    width = 0.35
    x = range(len(concurrent_users))
    
    plt.bar([i - width/2 for i in x], successful, width, label='Successful', color='green', alpha=0.7)
    plt.bar([i + width/2 for i in x], failed, width, label='Failed', color='red', alpha=0.7)
    
    plt.xlabel('Concurrent Users', fontsize=14, color=text_color)
    plt.ylabel('Number of Transactions', fontsize=14, color=text_color)
    plt.title('Successful vs Failed Transactions', fontsize=16, color=text_color)
    plt.xticks(x, concurrent_users)
    plt.legend()
    plt.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/success_failure_{timestamp}.{file_format}")
    plt.close()
    
    # 5. Combined performance metrics
    fig, ax1 = plt.subplots(figsize=(12, 7))
    
    color1 = 'tab:blue'
    ax1.set_xlabel('Concurrent Users', fontsize=14, color=text_color)
    ax1.set_ylabel('Response Time (s)', fontsize=14, color=color1)
    ax1.plot(concurrent_users, [r['response_time'] for r in results], 'o-', color=color1, linewidth=2, label='Response Time')
    ax1.tick_params(axis='y', labelcolor=color1)
    
    ax2 = ax1.twinx()
    color2 = 'tab:red'
    ax2.set_ylabel('Transaction Rate (tps)', fontsize=14, color=color2)
    ax2.plot(concurrent_users, [r['transaction_rate'] for r in results], 'o-', color=color2, linewidth=2, label='Transaction Rate')
    ax2.tick_params(axis='y', labelcolor=color2)
    
    fig.tight_layout()
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='upper center')
    plt.title('Performance Metrics vs Concurrent Users', fontsize=16, color=text_color)
    plt.grid(True, alpha=0.3)
    plt.savefig(f"{output_dir}/combined_metrics_{timestamp}.{file_format}")
    plt.close()
    
    print(f"Visualizations saved to {output_dir} directory")
    
    # Create summary report
    create_summary_report(data, results, output_dir, timestamp)

def create_summary_report(data, results, output_dir, timestamp):
    """Create a summary report in markdown format"""
    report_file = f"{output_dir}/benchmark_summary_{timestamp}.md"
    
    with open(report_file, 'w') as f:
        f.write(f"# Solr Benchmark Summary Report\n\n")
        f.write(f"Generated on: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        f.write(f"Target Solr URL: {data['solr_url']}\n")
        f.write(f"Benchmark timestamp: {data['benchmark_timestamp']}\n\n")
        
        f.write("## Performance Summary\n\n")
        f.write("| Concurrent Users | Response Time (s) | Transaction Rate | Availability (%) | Success | Failures |\n")
        f.write("|------------------|------------------|-----------------|-----------------|---------|----------|\n")
        
        for r in results:
            f.write(f"| {r['concurrent_users']} | {r['response_time']} | {r['transaction_rate']} | {r['availability']} | {r['successful_transactions']} | {r['failed_transactions']} |\n")
        
        f.write("\n## Key Findings\n\n")
        
        # Find best response time
        best_rt_index = min(range(len(results)), key=lambda i: results[i]['response_time'])
        f.write(f"- Best response time: {results[best_rt_index]['response_time']}s at {results[best_rt_index]['concurrent_users']} concurrent users\n")
        
        # Find maximum throughput
        max_tps_index = max(range(len(results)), key=lambda i: results[i]['transaction_rate'])
        f.write(f"- Maximum transaction rate: {results[max_tps_index]['transaction_rate']} tps at {results[max_tps_index]['concurrent_users']} concurrent users\n")
        
        # Check for any availability issues
        if any(r['availability'] < 99.5 for r in results):
            f.write("- **Warning**: Availability dropped below 99.5% in some test scenarios\n")
        
        # Look for scaling issues
        response_times = [r['response_time'] for r in results]
        if len(response_times) > 1 and response_times[-1] > 3 * response_times[0]:
            f.write("- **Scaling concern**: Response time increased significantly at higher concurrency levels\n")
        
        f.write("\n## Visualization Files\n\n")
        f.write(f"- response_time_{timestamp}.png - Response time vs concurrent users\n")
        f.write(f"- transaction_rate_{timestamp}.png - Transaction rate vs concurrent users\n")
        f.write(f"- availability_{timestamp}.png - Availability vs concurrent users\n")
        f.write(f"- success_failure_{timestamp}.png - Successful vs failed transactions\n")
        f.write(f"- combined_metrics_{timestamp}.png - Combined performance metrics\n")
    
    print(f"Summary report saved to {report_file}")

def main():
    args = parse_arguments()
    data = load_benchmark_data(args.input_file)
    text_color = setup_theme(args.theme)
    create_visualizations(data, args.output_dir, args.format, text_color)
if __name__ == "__main__":
    main()