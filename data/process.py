
def get_request_times(fname):
    with open(fname) as f:
        last_times = {}
        request_times = []
        for line in f:
            
            line = line.strip()
                        
            if line == "Work completed, terminating" or line == "":
                break
            
            components = line.split("; ")
            
            type_id = components[1].split(" ")
            if type_id[0] == "client" and (components[3] == "sending next request to primary" or components[3] == "no operations left"):
                id = int(type_id[1])
                time = float(components[0][5:])
                
                last_time = last_times.get(id)
                if last_time is not None:
                    request_times.append(time - last_time)
                last_times[id] = time
                
        return request_times

def get_viewchange_times_packets(fname):
    with open(fname) as f:
        n_packets = 0
        
        for line in f:
            line = line.strip()
            
            if line == "Work completed, terminating" or line == "":
                break
            
            components = line.split("; ")
            time = float(components[0][5:])
            
            if len(components) < 5:
                continue
            
            if time > 1000.0:
                n_pckts = int(components[4][:-13])
                n_packets +=  n_pckts
        
            if components[3] == "broadcast start view":
                time = float(components[0][5:])
                return (time - 1000.0, n_packets)

def build_request_times():
    for j in [19,21]:
        name = "params" + str(j) + "_request_times"
        with open(name, "w") as f:
            for i in range(0,10000):
                fname = "params" + str(j) + "/trace_" + str(i)
                request_times = get_request_times(fname)
                for r in request_times:
                    to_write = str(r) + "\n"
                    f.write(to_write)
                    
def build_viewchange_times():
    for j in range(22,23):
        t_name = "params" + str(j) + "_viewchange_times"
        p_name = "params" + str(j) + "_viewchange_packets"
        with open(t_name, "w") as t_f:
            with open(p_name, "w") as p_f:
                for i in range(0,10000):
                    fname = "params" + str(j) + "/trace_" + str(i)
                    viewchange_times, viewchange_packets = get_viewchange_times_packets(fname)
                    t_to_write = str(viewchange_times) + "\n"
                    p_to_write = str(viewchange_packets) + "\n"
                    t_f.write(t_to_write)
                    p_f.write(p_to_write)

import matplotlib.pyplot as plt
import numpy as np

from matplotlib import rc
rc('font', **{'family': 'serif', 'serif': ['Computer Modern']})
rc('text', usetex=True)

def cdf_times(fname, top_outliers, label):
    with open(fname) as f:
        lines = f.readlines()
        vals = np.array([float(line) for line in lines], dtype=np.float32)
        vals = np.sort(vals)
        if top_outliers > 0:
            vals = vals[:-top_outliers]
        percentages = 100. * np.arange(len(vals)) / (len(vals) - 1)
        
        print(vals)
        print(percentages)
        
        print(np.mean(vals), np.std(vals))
                
        plt.step(vals, percentages, where='post', label=label)
        plt.ylabel("Cumulative percentage")
        plt.ylim(0.0,100.0)
        #plt.show()

def plot_fr_request_times():
    cdf_times("params1_request_times", 2, "Base")
    cdf_times("params2_request_times", 1, "$500 \mu s$")
    cdf_times("params17_request_times", 2, "$750 \mu s$")
    cdf_times("params3_request_times", 2, "$1000 \mu s$")
    cdf_times("params4_request_times", 1, "$3000 \mu s$")
    #cdf_times("params5_request_times", 400.0, 3500.0, 1, "Fast Reads optimisation ($5000 \mu s$ lease)")

    plt.xlabel("Time for request to be serviced ($\mu s$)")
    plt.xlim(400.0, 3500.0)
    plt.legend(loc=2)
    plt.show()

def plot_pl_request_times(length, loc):
    cdf_times("params1_request_times", 2, "$0.0001$")
    cdf_times("params11_request_times", 0, "$0.001$")
    cdf_times("params12_request_times", 0, "$0.01$")
    cdf_times("params13_request_times", 2, "$0.1$")
    
    plt.xlabel("Time for request to be serviced ($\mu s$)")
    plt.xlim(1250.0, length)
    plt.legend(loc=loc)
    plt.show()


def plot_pt_request_times(length):
    cdf_times("params13_request_times", 2, "$3000 \mu s$")
    cdf_times("params14_request_times", 3, "$4000 \mu s$")
    cdf_times("params15_request_times", 5, "$5000 \mu s$")
    cdf_times("params16_request_times", 2, "$6000 \mu s$")
    
    plt.xlabel("Time for request to be serviced ($\mu s$)")
    plt.xlim(1250.0, length)
    plt.legend(loc=2)
    plt.show()
    
def plot_fr_viewchange_times():
    cdf_times("params6_viewchange_times", 0, "Base")
    #cdf_times("params7_viewchange_times", 0, "Fast Reads optimisation ($500 \mu s$ lease)")
    #cdf_times("params8_viewchange_times", 1, "Fast Reads optimisation ($1000 \mu s$ lease)")
    cdf_times("params9_viewchange_times", 0, "$3000 \mu s$")
    cdf_times("params22_viewchange_times", 0, "$4000 \mu s$")
    cdf_times("params10_viewchange_times", 0, "$5000 \mu s$")
    
    plt.xlabel("Time for view change ($\mu s$)")
    plt.xlim(4000.0, 7500.0)
    plt.legend(loc=4)
    plt.show()
    
def get_stats(fname, top_outliers):
    with open(fname) as f:
        lines = f.readlines()
        vals = np.array([float(line) for line in lines], dtype=np.float32)
        vals = np.sort(vals)
        if top_outliers > 0:
            vals = vals[:-top_outliers]
        
        print(vals)
        
        stdv = np.std(vals)
        mean = np.mean(vals)
        median = np.median(vals)
        
        print(mean, stdv, median)
        return mean, stdv, median

def mean_plot(labels, means, stdvs):
    sampling_stdvs = np.array(stdvs) / np.sqrt(10000)
    errs = [1.96 * stdv for stdv in sampling_stdvs]
    print(errs)
    index = range(len(labels))
    plt.scatter(index, means, c='k', s=5)
    plt.errorbar(index, means, ls='none', yerr=errs, c = 'k', capsize=5, elinewidth=1)
    plt.xticks(index, labels)
    
def plot_fr_request_means():
    fnames = ["params1_request_times","params2_request_times","params17_request_times","params3_request_times","params4_request_times"]
    labels = ["Base", "$750 \mu s$", "$1000 \mu s$", "$3000 \mu s$"]
    top_outliers_list = [2,1,2,2]
    zipped_fnames = zip(fnames, top_outliers_list)
    means, stdvs = list(map(list, zip(*[get_stats(fname, top_outliers) for fname, top_outliers in zipped_fnames])))[:-1]
    mean_plot(labels, means, stdvs)
    plt.ylabel("Mean time for request to be serviced ($\mu s$)")
    plt.tight_layout()
    plt.show()
    
def plot_pl_request_means():
    fnames = ["params1_request_times","params11_request_times","params12_request_times","params13_request_times"]
    labels = ["0.0001", "0.001", "0.01", "0.1"]
    top_outliers_list = [2,0,0,2]
    zipped_fnames = zip(fnames, top_outliers_list)
    means, stdvs = list(map(list, zip(*[get_stats(fname, top_outliers) for fname, top_outliers in zipped_fnames])))[:-1]
    mean_plot(labels, means, stdvs)
    plt.ylabel("Mean time for request to be serviced ($\mu s$)")
    plt.xlabel("Packet loss rate")
    plt.tight_layout()
    plt.show()
    
def plot_histogram(fname, top_outliers, label):
    with open(fname) as f:
        lines = f.readlines()
        vals = np.array([float(line) for line in lines], dtype=np.float32)
        vals = np.sort(vals)
        if top_outliers > 0:
            vals = vals[:-top_outliers]
            
        bins = np.unique([int(val) for val in vals])
        print(vals)
        
        plt.ylabel('Percentage')
        plt.hist(vals, bins, weights=100.0 * np.ones(len(vals)) / len(vals), label=label)
    
def plot_viewchange_packets_histogram():
    plot_histogram("params6_viewchange_packets", 0, "Base")
    plot_histogram("params10_viewchange_packets", 1, "$5000 \mu s$")
    
    plt.xlabel("Number of packets sent during view change")
    plt.legend(loc=9)
    plt.show()
    
def plot_preparetimeout_request_times():
    cdf_times("params13_request_times", 2, "$1600 \mu s$")
    cdf_times("params19_request_times", 3, "$1200 \mu s$")
    cdf_times("params21_request_times", 5, "$800 \mu s$")
    
    plt.xlabel("Time for request to be serviced ($\mu s$)")
    plt.xlim(1250.0, 10000.0)
    plt.legend(loc=4)
    plt.show()
    
def plot_pl_histogram():
    plot_histogram("params13_request_times", 2, "Base")
    
    plt.xlabel("Time for request to be serviced ($\mu s$)")
    plt.show()

plt.rcParams.update({'font.size': 18})
#plot_pt_request_times(10000.0)

#plot_pl_request_times(3500.0, 2)
#plot_pl_request_times(10000.0, 4)
#plot_pl_request_means()
#plot_pl_histogram()
#plot_preparetimeout_request_times()

#plot_fr_request_times()
#plot_fr_request_means()

#plot_fr_viewchange_times()
#plot_viewchange_packets_histogram()

