/*
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 */

#include <cctype>
#include <algorithm>
#include <functional>
#include <numeric>
#include <thrust/merge.h>
#include "cm.h"
#include "atof.h"
#include "compress.cu"
#include "sorts.cu"
#include "filter.h"

#ifdef _WIN64
#define atoll(S) _atoi64(S)
#endif


using namespace std;
using namespace thrust::placeholders;


std::clock_t tot = 0;
std::clock_t tot_fil = 0;
size_t total_count = 0, total_max;
unsigned int total_segments = 0;
unsigned int process_count;
map <unsigned int, size_t> str_offset;
size_t totalRecs = 0, alloced_sz = 0;
bool fact_file_loaded = 1;
char map_check;
void* d_v = NULL;
void* s_v = NULL;
queue<string> op_sort;
queue<string> op_presort;
queue<string> op_type;
queue<string> op_value;
queue<int_type> op_nums;
queue<float_type> op_nums_f;
queue<string> col_aliases;
bool write_sh = 1;

void* alloced_tmp;
bool alloced_switch = 0;

map<string,CudaSet*> varNames; //  STL map to manage CudaSet variables
map<string,string> setMap; //map to keep track of column names and set names


struct is_match
{
    __host__ __device__
    bool operator()(unsigned int x)
    {
        return x != 4294967295;
    }
};


struct f_equal_to
{
    __host__ __device__
    bool operator()(const float_type x, const float_type y)
    {
        return (((x-y) < EPSILON) && ((x-y) > -EPSILON));
    }
};


struct f_less
{
    __host__ __device__
    bool operator()(const float_type x, const float_type y)
    {
        return ((y-x) > EPSILON);
    }
};

struct f_greater
{
    __host__ __device__
    bool operator()(const float_type x, const float_type y)
    {
        return ((x-y) > EPSILON);
    }
};

struct f_greater_equal_to
{
    __host__ __device__
    bool operator()(const float_type x, const float_type y)
    {
        return (((x-y) > EPSILON) || (((x-y) < EPSILON) && ((x-y) > -EPSILON)));
    }
};

struct f_less_equal
{
    __host__ __device__
    bool operator()(const float_type x, const float_type y)
    {
        return (((y-x) > EPSILON) || (((x-y) < EPSILON) && ((x-y) > -EPSILON)));
    }
};

struct f_not_equal_to
{
    __host__ __device__
    bool operator()(const float_type x, const float_type y)
    {
        return !(((x-y) < EPSILON) && ((x-y) > -EPSILON));
    }
};


struct long_to_float_type
{
    __host__ __device__
    float_type operator()(const int_type x)
    {
        return (float_type)x;
    }
};


struct l_to_ui
{
    __host__ __device__
    float_type operator()(const int_type x)
    {
        return (unsigned int)x;
    }
};


struct to_zero
{
    __host__ __device__
    bool operator()(const int_type x)
    {
        if(x == -1)
            return 0;
        else
            return 1;
    }
};



struct div_long_to_float_type
{
    __host__ __device__
    float_type operator()(const int_type x, const float_type y)
    {
        return (float_type)x/y;
    }
};


struct long_to_float
{
    __host__ __device__
    float_type operator()(const long long int x)
    {
        return (((float_type)x)/100.0);
    }
};


// trim from start
static inline std::string &ltrim(std::string &s) {
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), std::not1(std::ptr_fun<int, int>(std::isspace))));
    return s;
}

// trim from end
static inline std::string &rtrim(std::string &s) {
    s.erase(std::find_if(s.rbegin(), s.rend(), std::not1(std::ptr_fun<int, int>(std::isspace))).base(), s.end());
    return s;
}

// trim from both ends
static inline std::string &trim(std::string &s) {
    return ltrim(rtrim(s));
}

char *mystrtok(char **m,char *s,char c)
{
    char *p=s?s:*m;
    if( !*p )
        return 0;
    *m=strchr(p,c);
    if( *m )
        *(*m)++=0;
    else
        *m=p+strlen(p);
    return p;
}


void allocColumns(CudaSet* a, queue<string> fields);
void copyColumns(CudaSet* a, queue<string> fields, unsigned int segment, size_t& count, bool rsz, bool flt);
void mygather(unsigned int tindex, unsigned int idx, CudaSet* a, CudaSet* t, size_t count, size_t g_size);
void mycopy(unsigned int tindex, unsigned int idx, CudaSet* a, CudaSet* t, size_t count, size_t g_size);
void write_compressed_char(string file_name, unsigned int index, size_t mCount);
size_t max_tmp(CudaSet* a);


unsigned int curr_segment = 10000000;

size_t getFreeMem();
char zone_map_check(queue<string> op_type, queue<string> op_value, queue<int_type> op_nums,queue<float_type> op_nums_f, CudaSet* a, unsigned int segment);
void filter_op(char *s, char *f, unsigned int segment);

float total_time1 = 0;


CudaSet::CudaSet(queue<string> &nameRef, queue<string> &typeRef, queue<int> &sizeRef, queue<int> &colsRef, size_t Recs)
    : mColumnCount(0), mRecCount(0)
{
    initialize(nameRef, typeRef, sizeRef, colsRef, Recs);
    keep = false;
    source = 1;
    text_source = 1;
    grp = NULL;
};

CudaSet::CudaSet(queue<string> &nameRef, queue<string> &typeRef, queue<int> &sizeRef, queue<int> &colsRef, size_t Recs, string file_name)
    : mColumnCount(0),  mRecCount(0)
{
    initialize(nameRef, typeRef, sizeRef, colsRef, Recs, file_name);
    keep = false;
    source = 1;
    text_source = 0;
    grp = NULL;
};

CudaSet::CudaSet(size_t RecordCount, unsigned int ColumnCount)
{
    initialize(RecordCount, ColumnCount);
    keep = false;
    source = 0;
    text_source = 0;
    grp = NULL;
};

CudaSet::CudaSet(queue<string> op_sel, queue<string> op_sel_as)
{
    initialize(op_sel, op_sel_as);
    keep = false;
    source = 0;
    text_source = 0;
    grp = NULL;
};

CudaSet::CudaSet(CudaSet* a, CudaSet* b, queue<string> op_sel, queue<string> op_sel_as)
{
    initialize(a,b, op_sel, op_sel_as);
    keep = false;
    source = 0;
    text_source = 0;
    grp = NULL;
};


CudaSet::~CudaSet()
{
    free();
};


void CudaSet::allocColumnOnDevice(unsigned int colIndex, size_t RecordCount)
{
    if (type[colIndex] == 0) {
        d_columns_int[type_index[colIndex]].resize(RecordCount);
    }
    else if (type[colIndex] == 1)
        d_columns_float[type_index[colIndex]].resize(RecordCount);
    else {
        void* d;
        size_t sz = RecordCount*char_size[type_index[colIndex]];
        cudaError_t cudaStatus = cudaMalloc(&d, sz);
        if(cudaStatus != cudaSuccess) {
            cout << "Could not allocate " << sz << " bytes of GPU memory for " << RecordCount << " records " << endl;
            exit(0);
        };
        d_columns_char[type_index[colIndex]] = (char*)d;
    };
};


void CudaSet::decompress_char_hash(unsigned int colIndex, unsigned int segment, size_t i_cnt)
{

    unsigned int bits_encoded, fit_count, sz, vals_count, real_count;
    size_t old_count;
    const unsigned int len = char_size[type_index[colIndex]];

    string f1 = load_file_name + "." + std::to_string(cols[colIndex]) + "." + std::to_string(segment);

    FILE* f;
    f = fopen (f1.c_str() , "rb" );
    fread(&sz, 4, 1, f);
    char* d_array = new char[sz*len];
    fread((void*)d_array, sz*len, 1, f);

    unsigned long long int* hashes  = new unsigned long long int[sz];

    for(unsigned int i = 0; i < sz ; i++) {
        hashes[i] = MurmurHash64A(&d_array[i*len], len, hash_seed); // divide by 2 so it will fit into a signed long long
    };

    void* d;
    cudaMalloc((void **) &d, sz*int_size);
    cudaMemcpy( d, (void *) hashes, sz*8, cudaMemcpyHostToDevice);

    thrust::device_ptr<unsigned long long int> dd_int((unsigned long long int*)d);

    delete[] d_array;
    delete[] hashes;

    fread(&fit_count, 4, 1, f);
    fread(&bits_encoded, 4, 1, f);
    fread(&vals_count, 4, 1, f);
    fread(&real_count, 4, 1, f);

    unsigned long long int* int_array = new unsigned long long int[vals_count];
    fread((void*)int_array, 1, vals_count*8, f);
    fclose(f);

    void* d_val;
    cudaMalloc((void **) &d_val, vals_count*8);
    cudaMemcpy(d_val, (void *) int_array, vals_count*8, cudaMemcpyHostToDevice);

    thrust::device_ptr<unsigned long long int> mval((unsigned long long int*)d_val);
    delete[] int_array;
    void* d_int;
    cudaMalloc((void **) &d_int, real_count*4);

    // convert bits to ints and then do gather

    void* d_v;
    cudaMalloc((void **) &d_v, 8);
    thrust::device_ptr<unsigned int> dd_v((unsigned int*)d_v);
    dd_v[1] = fit_count;
    dd_v[0] = bits_encoded;

    thrust::counting_iterator<unsigned int> begin(0);
    decompress_functor_str ff((unsigned long long int*)d_val,(unsigned int*)d_int, (unsigned int*)d_v);
    thrust::for_each(begin, begin + real_count, ff);

    thrust::device_ptr<unsigned int> dd_val((unsigned int*)d_int);

    if(filtered) {
        if(prm_index == 'R') {
            thrust::device_ptr<int_type> d_tmp = thrust::device_malloc<int_type>(real_count);
            thrust::gather(dd_val, dd_val + real_count, dd_int, d_tmp);
            old_count = d_columns_int[i_cnt].size();
            d_columns_int[i_cnt].resize(old_count + mRecCount);
            thrust::gather(prm_d.begin(), prm_d.begin() + mRecCount, d_tmp, d_columns_int[i_cnt].begin() + old_count);
            thrust::device_free(d_tmp);

        }
        else if(prm_index == 'A') {
            old_count = d_columns_int[i_cnt].size();
            d_columns_int[i_cnt].resize(old_count + real_count);
            thrust::gather(dd_val, dd_val + real_count, dd_int, d_columns_int[i_cnt].begin() + old_count);
        }
    }
    else {
        old_count = d_columns_int[i_cnt].size();
        d_columns_int[i_cnt].resize(old_count + real_count);
        thrust::gather(dd_val, dd_val + real_count, dd_int, d_columns_int[i_cnt].begin() + old_count);
    };

    cudaFree(d);
    cudaFree(d_val);
    cudaFree(d_v);
    cudaFree(d_int);
};




// takes a char column , hashes strings, copies them to a gpu
void CudaSet::add_hashed_strings(string field, unsigned int segment, size_t i_cnt)
{
    unsigned int colInd2 = columnNames.find(field)->second;
    CudaSet *t = varNames[setMap[field]];

    if(not_compressed) { // decompressed strings on a host

        size_t old_count;
        unsigned long long int* hashes  = new unsigned long long int[t->mRecCount];

        for(unsigned int i = 0; i < t->mRecCount ; i++) {
            hashes[i] = MurmurHash64A(t->h_columns_char[t->type_index[colInd2]] + i*t->char_size[t->type_index[colInd2]] + segment*t->maxRecs*t->char_size[t->type_index[colInd2]], t->char_size[t->type_index[colInd2]], hash_seed);
        };

        if(filtered) {

            if(prm_index == 'R') {

                thrust::device_ptr<unsigned long long int> d_tmp = thrust::device_malloc<unsigned long long int>(t->mRecCount);
                thrust::copy(hashes, hashes+mRecCount, d_tmp);
                old_count = d_columns_int[i_cnt].size();
                d_columns_int[i_cnt].resize(old_count + mRecCount);
                thrust::gather(prm_d.begin(), prm_d.begin() + mRecCount, d_tmp, d_columns_int[i_cnt].begin() + old_count);
                thrust::device_free(d_tmp);

            }
            else if(prm_index == 'A') {
                old_count = d_columns_int[i_cnt].size();
                d_columns_int[i_cnt].resize(old_count + mRecCount);
                thrust::copy(hashes, hashes + mRecCount, d_columns_int[i_cnt].begin() + old_count);
            }
        }
        else {

            old_count = d_columns_int[i_cnt].size();
            d_columns_int[i_cnt].resize(old_count + mRecCount);
            thrust::copy(hashes, hashes + mRecCount, d_columns_int[i_cnt].begin() + old_count);
        }
        delete [] hashes;
    }
    else { // hash the dictionary
        decompress_char_hash(colInd2, segment, i_cnt);
    };
};


void CudaSet::resize_join(size_t addRecs)
{
    mRecCount = mRecCount + addRecs;
    bool prealloc = 0;
    for(unsigned int i=0; i < mColumnCount; i++) {
        if(type[i] == 0) {
            h_columns_int[type_index[i]].resize(mRecCount);
        }
        else if(type[i] == 1) {
            h_columns_float[type_index[i]].resize(mRecCount);
        }
        else {
            if (h_columns_char[type_index[i]]) {
                if (mRecCount > prealloc_char_size) {
                    h_columns_char[type_index[i]] = (char*)realloc(h_columns_char[type_index[i]], mRecCount*char_size[type_index[i]]);
                    prealloc = 1;
                };
            }
            else {
                h_columns_char[type_index[i]] = new char[mRecCount*char_size[type_index[i]]];
            };
        };

    };
    if(prealloc)
        prealloc_char_size = mRecCount;
};


void CudaSet::resize(size_t addRecs)
{
    mRecCount = mRecCount + addRecs;
    for(unsigned int i=0; i <mColumnCount; i++) {
        if(type[i] == 0) {
            h_columns_int[type_index[i]].resize(mRecCount);
        }
        else if(type[i] == 1) {
            h_columns_float[type_index[i]].resize(mRecCount);
        }
        else {
            if (h_columns_char[type_index[i]]) {
                h_columns_char[type_index[i]] = (char*)realloc(h_columns_char[type_index[i]], mRecCount*char_size[type_index[i]]);
            }
            else {
                h_columns_char[type_index[i]] = new char[mRecCount*char_size[type_index[i]]];
            };
        };

    };
};

void CudaSet::reserve(size_t Recs)
{

    for(unsigned int i=0; i <mColumnCount; i++) {
        if(type[i] == 0)
            h_columns_int[type_index[i]].reserve(Recs);
        else if(type[i] == 1)
            h_columns_float[type_index[i]].reserve(Recs);
        else {
            h_columns_char[type_index[i]] = new char[Recs*char_size[type_index[i]]];
            if(h_columns_char[type_index[i]] == NULL) {
                cout << "Could not allocate on a host " << Recs << " records of size " << char_size[type_index[i]] << endl;
                exit(0);
            };
            prealloc_char_size = Recs;
        };

    };
};


void CudaSet::deAllocColumnOnDevice(unsigned int colIndex)
{
    if (type[colIndex] == 0 && !d_columns_int.empty()) {
        d_columns_int[type_index[colIndex]].resize(0);
        d_columns_int[type_index[colIndex]].shrink_to_fit();
    }
    else if (type[colIndex] == 1 && !d_columns_float.empty()) {
        d_columns_float[type_index[colIndex]].resize(0);
        d_columns_float[type_index[colIndex]].shrink_to_fit();
    }
    else if (type[colIndex] == 2 && d_columns_char[type_index[colIndex]] != NULL) {
        cudaFree(d_columns_char[type_index[colIndex]]);
        d_columns_char[type_index[colIndex]] = NULL;
    };
};

void CudaSet::allocOnDevice(size_t RecordCount)
{
    for(unsigned int i=0; i < mColumnCount; i++)
        allocColumnOnDevice(i, RecordCount);
};

void CudaSet::deAllocOnDevice()
{
    for(unsigned int i=0; i <mColumnCount; i++)
        deAllocColumnOnDevice(i);

    if(!columnGroups.empty() && mRecCount !=0) {
        cudaFree(grp);
        grp = NULL;
    };

    if(filtered) { // free the sources
        string some_field;
        auto it=columnNames.begin();
        some_field = (*it).first;

        if(setMap[some_field].compare(name)) {
            CudaSet* t = varNames[setMap[some_field]];
            t->deAllocOnDevice();
        };
    };
};

void CudaSet::resizeDeviceColumn(size_t RecCount, unsigned int colIndex)
{
//   if (RecCount) {
    if (type[colIndex] == 0) {
        d_columns_int[type_index[colIndex]].resize(mRecCount+RecCount);
    }
    else if (type[colIndex] == 1)
        d_columns_float[type_index[colIndex]].resize(mRecCount+RecCount);
    else {
        if (d_columns_char[type_index[colIndex]] != NULL)
            cudaFree(d_columns_char[type_index[colIndex]]);
        void *d;
        cudaMalloc((void **) &d, (mRecCount+RecCount)*char_size[type_index[colIndex]]);
        d_columns_char[type_index[colIndex]] = (char*)d;
    };
//    };
};



void CudaSet::resizeDevice(size_t RecCount)
{
    //  if (RecCount)
    for(unsigned int i=0; i < mColumnCount; i++)
        resizeDeviceColumn(RecCount, i);
};

bool CudaSet::onDevice(unsigned int i)
{
    size_t j = type_index[i];

    if (type[i] == 0) {
        if (d_columns_int.empty())
            return 0;
        if (d_columns_int[j].size() == 0)
            return 0;
    }
    else if (type[i] == 1) {
        if (d_columns_float.empty())
            return 0;
        if(d_columns_float[j].size() == 0)
            return 0;
    }
    else if  (type[i] == 2) {
        if(d_columns_char.empty())
            return 0;
        if(d_columns_char[j] == NULL)
            return 0;
    };
    return 1;
}



CudaSet* CudaSet::copyDeviceStruct()
{

    CudaSet* a = new CudaSet(mRecCount, mColumnCount);
    a->not_compressed = not_compressed;
    a->segCount = segCount;
    a->maxRecs = maxRecs;

    for ( auto it=columnNames.begin() ; it != columnNames.end(); ++it )
        a->columnNames[(*it).first] = (*it).second;

    for(unsigned int i=0; i < mColumnCount; i++) {
        a->cols[i] = cols[i];
        a->type[i] = type[i];

        if(a->type[i] == 0) {
            a->d_columns_int.push_back(thrust::device_vector<int_type>());
            a->h_columns_int.push_back(thrust::host_vector<int_type, uninitialized_host_allocator<int_type> >());
            a->type_index[i] = a->d_columns_int.size()-1;
        }
        else if(a->type[i] == 1) {
            a->d_columns_float.push_back(thrust::device_vector<float_type>());
            a->h_columns_float.push_back(thrust::host_vector<float_type, uninitialized_host_allocator<float_type> >());
            a->type_index[i] = a->d_columns_float.size()-1;
            a->decimal[i] = decimal[i];
        }
        else {
            a->h_columns_char.push_back(NULL);
            a->d_columns_char.push_back(NULL);
            a->type_index[i] = a->d_columns_char.size()-1;
            a->char_size.push_back(char_size[type_index[i]]);
        };
    };
    a->load_file_name = load_file_name;

    a->mRecCount = 0;
    return a;
}


void CudaSet::readSegmentsFromFile(unsigned int segNum, unsigned int colIndex)
{

    string f1(load_file_name);
    f1 += "." + std::to_string(cols[colIndex]) + "." + std::to_string(segNum);
    unsigned int cnt;

    FILE* f;
    f = fopen(f1.c_str(), "rb" );
    if(f == NULL) {
        cout << "Error opening " << f1 << " file " << endl;
        exit(0);
    };
    size_t rr;


    if(type[colIndex] == 0) {
        fread(h_columns_int[type_index[colIndex]].data(), 4, 1, f);
        cnt = ((unsigned int*)(h_columns_int[type_index[colIndex]].data()))[0];
        //cout << "start fread " << f1 << " " << (cnt+8)*8 - 4 << endl;
        rr = fread((unsigned int*)(h_columns_int[type_index[colIndex]].data()) + 1, 1, (cnt+8)*8 - 4, f);
        if(rr != (cnt+8)*8 - 4) {
            cout << "Couldn't read  " << (cnt+8)*8 - 4 << " bytes from " << f1  << endl;
            exit(0);
        };
        //cout << "end fread " << rr << endl;
    }
    else if(type[colIndex] == 1) {
        fread(h_columns_float[type_index[colIndex]].data(), 4, 1, f);
        cnt = ((unsigned int*)(h_columns_float[type_index[colIndex]].data()))[0];
        //cout << "start fread " << f1 << " " << (cnt+8)*8 - 4 << endl;
        rr = fread((unsigned int*)(h_columns_float[type_index[colIndex]].data()) + 1, 1, (cnt+8)*8 - 4, f);
        if(rr != (cnt+8)*8 - 4) {
            cout << "Couldn't read  " << (cnt+8)*8 - 4 << " bytes from " << f1  << endl;
            exit(0);
        };
        //cout << "end fread " << rr << endl;
    }
    else {
        decompress_char(f, colIndex, segNum);
    };
    fclose(f);
};


void CudaSet::decompress_char(FILE* f, unsigned int colIndex, unsigned int segNum)
{
    unsigned int bits_encoded, fit_count, sz, vals_count, real_count;
    const unsigned int len = char_size[type_index[colIndex]];

    fread(&sz, 4, 1, f);
    char* d_array = new char[sz*len];
    fread((void*)d_array, sz*len, 1, f);
    void* d;
    cudaMalloc((void **) &d, sz*len);
    cudaMemcpy( d, (void *) d_array, sz*len, cudaMemcpyHostToDevice);
    delete[] d_array;


    fread(&fit_count, 4, 1, f);
    fread(&bits_encoded, 4, 1, f);
    fread(&vals_count, 4, 1, f);
    fread(&real_count, 4, 1, f);

    thrust::device_ptr<unsigned int> param = thrust::device_malloc<unsigned int>(2);
    param[1] = fit_count;
    param[0] = bits_encoded;

    unsigned long long int* int_array = new unsigned long long int[vals_count];
    fread((void*)int_array, 1, vals_count*8, f);
    //fclose(f);

    void* d_val;
    cudaMalloc((void **) &d_val, vals_count*8);
    cudaMemcpy(d_val, (void *) int_array, vals_count*8, cudaMemcpyHostToDevice);
    delete[] int_array;

    void* d_int;
    cudaMalloc((void **) &d_int, real_count*4);

    // convert bits to ints and then do gather


    thrust::counting_iterator<unsigned int> begin(0);
    decompress_functor_str ff((unsigned long long int*)d_val,(unsigned int*)d_int, (unsigned int*)thrust::raw_pointer_cast(param));
    thrust::for_each(begin, begin + real_count, ff);

    //thrust::device_ptr<unsigned int> dd_r((unsigned int*)d_int);
    //for(int z = 0 ; z < 3; z++)
    //cout << "DD " << dd_r[z] << endl;

    //void* d_char;
    //cudaMalloc((void **) &d_char, real_count*len);
    //cudaMemset(d_char, 0, real_count*len);
    //str_gather(d_int, real_count, d, d_char, len);
    if(str_offset.count(colIndex) == 0)
        str_offset[colIndex] = 0;
    //cout << "str off " << str_offset[colIndex] << endl;
    //cout << "prm cnt of seg " << segNum << " is " << prm.empty() << endl;
    if(!alloced_switch)
        str_gather(d_int, real_count, d, d_columns_char[type_index[colIndex]] + str_offset[colIndex]*len, len);
    else
        str_gather(d_int, real_count, d, alloced_tmp, len);


    if(filtered) {
        str_offset[colIndex] = str_offset[colIndex] + prm_d.size();
    }
    else {
        str_offset[colIndex] = str_offset[colIndex] + real_count;
    };

    //if(d_columns_char[type_index[colIndex]])
    //    cudaFree(d_columns_char[type_index[colIndex]]);
    //d_columns_char[type_index[colIndex]] = (char*)d_char;

    mRecCount = real_count;

    cudaFree(d);
    cudaFree(d_val);
    thrust::device_free(param);
    cudaFree(d_int);
}



void CudaSet::CopyColumnToGpu(unsigned int colIndex,  unsigned int segment, size_t offset)
{
    if(not_compressed) 	{
        // calculate how many records we need to copy
        if(segment < segCount-1) {
            mRecCount = maxRecs;
        }
        else {
            mRecCount = hostRecCount - maxRecs*(segCount-1);
        };

        switch(type[colIndex]) {
        case 0 :
            if(!alloced_switch)
                thrust::copy(h_columns_int[type_index[colIndex]].begin() + maxRecs*segment, h_columns_int[type_index[colIndex]].begin() + maxRecs*segment + mRecCount, d_columns_int[type_index[colIndex]].begin() + offset);
            else {
                thrust::device_ptr<int_type> d_col((int_type*)alloced_tmp);
                thrust::copy(h_columns_int[type_index[colIndex]].begin() + maxRecs*segment, h_columns_int[type_index[colIndex]].begin() + maxRecs*segment + mRecCount, d_col);
            };
            break;
        case 1 :
            if(!alloced_switch) {
                thrust::copy(h_columns_float[type_index[colIndex]].begin() + maxRecs*segment, h_columns_float[type_index[colIndex]].begin() + maxRecs*segment + mRecCount, d_columns_float[type_index[colIndex]].begin() + offset);
            }
            else {
                thrust::device_ptr<float_type> d_col((float_type*)alloced_tmp);
                thrust::copy(h_columns_float[type_index[colIndex]].begin() + maxRecs*segment, h_columns_float[type_index[colIndex]].begin() + maxRecs*segment + mRecCount, d_col);
            };
            break;
        default :
            if(!alloced_switch) {
                cudaMemcpy(d_columns_char[type_index[colIndex]] + char_size[type_index[colIndex]]*offset, h_columns_char[type_index[colIndex]] + maxRecs*segment*char_size[type_index[colIndex]], char_size[type_index[colIndex]]*mRecCount, cudaMemcpyHostToDevice);
            }
            else
                cudaMemcpy(alloced_tmp , h_columns_char[type_index[colIndex]] + maxRecs*segment*char_size[type_index[colIndex]], char_size[type_index[colIndex]]*mRecCount, cudaMemcpyHostToDevice);
        };
    }
    else {

        readSegmentsFromFile(segment,colIndex);

        if(type[colIndex] != 2) {
            if(d_v == NULL)
                CUDA_SAFE_CALL(cudaMalloc((void **) &d_v, 12));
            if(s_v == NULL)
                CUDA_SAFE_CALL(cudaMalloc((void **) &s_v, 8));
        };

        if(type[colIndex] == 0) {
            if(!alloced_switch) {
                mRecCount = pfor_decompress(thrust::raw_pointer_cast(d_columns_int[type_index[colIndex]].data()), h_columns_int[type_index[colIndex]].data(), d_v, s_v);
            }
            else {
                mRecCount = pfor_decompress(alloced_tmp, h_columns_int[type_index[colIndex]].data(), d_v, s_v);
            };
        }
        else if(type[colIndex] == 1) {
            if(decimal[colIndex]) {
                if(!alloced_switch) {
                    mRecCount = pfor_decompress( thrust::raw_pointer_cast(d_columns_float[type_index[colIndex]].data()) , h_columns_float[type_index[colIndex]].data(), d_v, s_v);
                    thrust::device_ptr<long long int> d_col_int((long long int*)thrust::raw_pointer_cast(d_columns_float[type_index[colIndex]].data()));
                    thrust::transform(d_col_int,d_col_int+mRecCount,d_columns_float[type_index[colIndex]].begin(), long_to_float());
                }
                else {
                    mRecCount = pfor_decompress(alloced_tmp, h_columns_float[type_index[colIndex]].data(), d_v, s_v);
                    thrust::device_ptr<long long int> d_col_int((long long int*)alloced_tmp);
                    thrust::device_ptr<float_type> d_col_float((float_type*)alloced_tmp);
                    thrust::transform(d_col_int,d_col_int+mRecCount, d_col_float, long_to_float());
                };
            }
            //else // uncompressed float
            //cudaMemcpy( d_columns[colIndex], (void *) ((float_type*)h_columns[colIndex] + offset), count*float_size, cudaMemcpyHostToDevice);
            // will have to fix it later so uncompressed data will be written by segments too
        }
    };
}



void CudaSet::CopyColumnToGpu(unsigned int colIndex) // copy all segments
{
    if(not_compressed) {
        switch(type[colIndex]) {
        case 0 :
            thrust::copy(h_columns_int[type_index[colIndex]].begin(), h_columns_int[type_index[colIndex]].begin() + mRecCount, d_columns_int[type_index[colIndex]].begin());
            break;
        case 1 :
            thrust::copy(h_columns_float[type_index[colIndex]].begin(), h_columns_float[type_index[colIndex]].begin() + mRecCount, d_columns_float[type_index[colIndex]].begin());
            break;
        default :
            cudaMemcpy(d_columns_char[type_index[colIndex]], h_columns_char[type_index[colIndex]], char_size[type_index[colIndex]]*mRecCount, cudaMemcpyHostToDevice);
        };
    }
    else {
        size_t totalRecs = 0;
        if(d_v == NULL)
            CUDA_SAFE_CALL(cudaMalloc((void **) &d_v, 12));
        if(s_v == NULL)
            CUDA_SAFE_CALL(cudaMalloc((void **) &s_v, 8));

        str_offset[colIndex] = 0;
        for(unsigned int i = 0; i < segCount; i++) {

            readSegmentsFromFile(i,colIndex);


            if(type[colIndex] == 0) {
                mRecCount = pfor_decompress(thrust::raw_pointer_cast(d_columns_int[type_index[colIndex]].data() + totalRecs), h_columns_int[type_index[colIndex]].data(), d_v, s_v);
            }
            else if(type[colIndex] == 1) {
                if(decimal[colIndex]) {
                    mRecCount = pfor_decompress( thrust::raw_pointer_cast(d_columns_float[type_index[colIndex]].data() + totalRecs) , h_columns_float[type_index[colIndex]].data(), d_v, s_v);
                    thrust::device_ptr<long long int> d_col_int((long long int*)thrust::raw_pointer_cast(d_columns_float[type_index[colIndex]].data() + totalRecs));
                    thrust::transform(d_col_int,d_col_int+mRecCount,d_columns_float[type_index[colIndex]].begin() + totalRecs, long_to_float());
                }
                // else  uncompressed float
                //cudaMemcpy( d_columns[colIndex], (void *) ((float_type*)h_columns[colIndex] + offset), count*float_size, cudaMemcpyHostToDevice);
                // will have to fix it later so uncompressed data will be written by segments too
            };

            totalRecs = totalRecs + mRecCount;
        };

        mRecCount = totalRecs;
    };
}



void CudaSet::CopyColumnToHost(int colIndex, size_t offset, size_t RecCount)
{

    switch(type[colIndex]) {
    case 0 :
        thrust::copy(d_columns_int[type_index[colIndex]].begin(), d_columns_int[type_index[colIndex]].begin() + RecCount, h_columns_int[type_index[colIndex]].begin() + offset);
        break;
    case 1 :
        thrust::copy(d_columns_float[type_index[colIndex]].begin(), d_columns_float[type_index[colIndex]].begin() + RecCount, h_columns_float[type_index[colIndex]].begin() + offset);
        break;
    default :
        cudaMemcpy(h_columns_char[type_index[colIndex]] + offset*char_size[type_index[colIndex]], d_columns_char[type_index[colIndex]], char_size[type_index[colIndex]]*RecCount, cudaMemcpyDeviceToHost);
    }
}



void CudaSet::CopyColumnToHost(int colIndex)
{
    CopyColumnToHost(colIndex, 0, mRecCount);
}

void CudaSet::CopyToHost(size_t offset, size_t count)
{
    for(unsigned int i = 0; i < mColumnCount; i++) {
        CopyColumnToHost(i, offset, count);
    };
}

float_type* CudaSet::get_float_type_by_name(string name)
{
    unsigned int colIndex = columnNames.find(name)->second;
    return thrust::raw_pointer_cast(d_columns_float[type_index[colIndex]].data());
}

int_type* CudaSet::get_int_by_name(string name)
{
    unsigned int colIndex = columnNames.find(name)->second;
    return thrust::raw_pointer_cast(d_columns_int[type_index[colIndex]].data());
}

float_type* CudaSet::get_host_float_by_name(string name)
{
    unsigned int colIndex = columnNames.find(name)->second;
    return thrust::raw_pointer_cast(h_columns_float[type_index[colIndex]].data());
}

int_type* CudaSet::get_host_int_by_name(string name)
{
    unsigned int colIndex = columnNames.find(name)->second;
    return thrust::raw_pointer_cast(h_columns_int[type_index[colIndex]].data());
}



void CudaSet::GroupBy(stack<string> columnRef, unsigned int int_col_count)
{
    unsigned int colIndex;

    if(grp)
        cudaFree(grp);

    CUDA_SAFE_CALL(cudaMalloc((void **) &grp, mRecCount * sizeof(bool)));
    thrust::device_ptr<bool> d_grp(grp);

    thrust::sequence(d_grp, d_grp+mRecCount, 0, 0);

    thrust::device_ptr<bool> d_group = thrust::device_malloc<bool>(mRecCount);

    d_group[mRecCount-1] = 1;
    unsigned int i_count = 0;

    for(int i = 0; i < columnRef.size(); columnRef.pop()) {

        columnGroups.push(columnRef.top()); // save for future references
        colIndex = columnNames[columnRef.top()];


        if (type[colIndex] == 0) {  // int_type
            thrust::transform(d_columns_int[type_index[colIndex]].begin(), d_columns_int[type_index[colIndex]].begin() + mRecCount - 1,
                              d_columns_int[type_index[colIndex]].begin()+1, d_group, thrust::not_equal_to<int_type>());
        }
        else if (type[colIndex] == 1) {  // float_type
            thrust::transform(d_columns_float[type_index[colIndex]].begin(), d_columns_float[type_index[colIndex]].begin() + mRecCount - 1,
                              d_columns_float[type_index[colIndex]].begin()+1, d_group, f_not_equal_to());
        }
        else  {  // Char
            //str_grp(d_columns_char[type_index[colIndex]], mRecCount, d_group, char_size[type_index[colIndex]]);
            //use int_type

            thrust::transform(d_columns_int[int_col_count+i_count].begin(), d_columns_int[int_col_count+i_count].begin() + mRecCount - 1,
                              d_columns_int[int_col_count+i_count].begin()+1, d_group, thrust::not_equal_to<int_type>());
            i_count++;

        };
        thrust::transform(d_group, d_group+mRecCount, d_grp, d_grp, thrust::logical_or<bool>());

    };

    thrust::device_free(d_group);
    grp_count = thrust::count(d_grp, d_grp+mRecCount,1);
};


void CudaSet::addDeviceColumn(int_type* col, int colIndex, string colName, size_t recCount)
{
    if (columnNames.find(colName) == columnNames.end()) {
        columnNames[colName] = colIndex;
        type[colIndex] = 0;
        d_columns_int.push_back(thrust::device_vector<int_type>(recCount));
        h_columns_int.push_back(thrust::host_vector<int_type, uninitialized_host_allocator<int_type> >());
        type_index[colIndex] = d_columns_int.size()-1;
    }
    else {  // already exists, my need to resize it
        if(d_columns_int[type_index[colIndex]].size() < recCount) {
            d_columns_int[type_index[colIndex]].resize(recCount);
        };
    };
    // copy data to d columns
    thrust::device_ptr<int_type> d_col((int_type*)col);
    thrust::copy(d_col, d_col+recCount, d_columns_int[type_index[colIndex]].begin());
};

void CudaSet::addDeviceColumn(float_type* col, int colIndex, string colName, size_t recCount)
{
    if (columnNames.find(colName) == columnNames.end()) {
        columnNames[colName] = colIndex;
        type[colIndex] = 1;
        d_columns_float.push_back(thrust::device_vector<float_type>(recCount));
        h_columns_float.push_back(thrust::host_vector<float_type, uninitialized_host_allocator<float_type> >());
        type_index[colIndex] = d_columns_float.size()-1;
    }
    else {  // already exists, my need to resize it
        if(d_columns_float[type_index[colIndex]].size() < recCount)
            d_columns_float[type_index[colIndex]].resize(recCount);
    };

    thrust::device_ptr<float_type> d_col((float_type*)col);
    thrust::copy(d_col, d_col+recCount, d_columns_float[type_index[colIndex]].begin());
};

void CudaSet::compress(string file_name, size_t offset, unsigned int check_type, unsigned int check_val, void* d, size_t mCount)
{
    string str(file_name);
    thrust::device_vector<unsigned int> permutation;

    total_count = total_count + mCount;
    //total_segments = total_segments + 1;
    if (mCount > total_max && op_sort.empty()) {
        total_max = mCount;
	};	

    if(!op_sort.empty()) { //sort the segment
        //copy the key columns to device
        queue<string> sf(op_sort);

        permutation.resize(mRecCount);
        thrust::sequence(permutation.begin(), permutation.begin() + mRecCount,0,1);
        unsigned int* raw_ptr = thrust::raw_pointer_cast(permutation.data());
        void* temp;

        size_t max_c = max_char(this, sf);

        if(max_c > float_size)
            CUDA_SAFE_CALL(cudaMalloc((void **) &temp, mRecCount*max_c));
        else
            CUDA_SAFE_CALL(cudaMalloc((void **) &temp, mRecCount*float_size));

        string sort_type = "ASC";

        while(!sf.empty()) {
            int colInd = columnNames[sf.front()];

            allocColumnOnDevice(colInd, maxRecs);
            CopyColumnToGpu(colInd);

            if (type[colInd] == 0)
                update_permutation(d_columns_int[type_index[colInd]], raw_ptr, mRecCount, sort_type, (int_type*)temp);
            else if (type[colInd] == 1)
                update_permutation(d_columns_float[type_index[colInd]], raw_ptr, mRecCount, sort_type, (float_type*)temp);
            else {
                update_permutation_char(d_columns_char[type_index[colInd]], raw_ptr, mRecCount, sort_type, (char*)temp, char_size[type_index[colInd]]);
            };
            deAllocColumnOnDevice(colInd);
            sf.pop();
        };
        cudaFree(temp);
    };

	// here we need to check for partitions and if partition_count > 0 -> create partitions
	if(mCount < partition_count || partition_count == 0)
		partition_count = 1;
	unsigned int partition_recs = mCount/partition_count;
	cout << "partition recs " << partition_recs << endl;

	if(!op_sort.empty()) {
	    if(total_max < partition_recs)
			total_max = partition_recs;
	};	
	
	//for(unsigned int p = 0; p < partition_count; p++) {
	//    cout << "partition " << p << endl;
	total_segments++;
	auto old_segments = total_segments;
	size_t new_offset;
	for(unsigned int i = 0; i< mColumnCount; i++) {
		str = file_name + "." + std::to_string(cols[i]);
		curr_file = str;
		str += "." + std::to_string(total_segments-1);
		new_offset = 0;

		if(!op_sort.empty()) {
			allocColumnOnDevice(i, maxRecs);
			CopyColumnToGpu(i);
		};		

		if(type[i] == 0) {
			thrust::device_ptr<int_type> d_col((int_type*)d);
			if(!op_sort.empty()) {
				thrust::gather(permutation.begin(), permutation.end(), d_columns_int[type_index[i]].begin(), d_col);
				
				for(unsigned int p = 0; p < partition_count; p++) {
					str = file_name + "." + std::to_string(cols[i]);
					curr_file = str;
					str += "." + std::to_string(total_segments-1);
					if (p < partition_count - 1) {
						pfor_compress( (int_type*)d + new_offset, partition_recs*int_size, str, h_columns_int[type_index[i]], 0);
					}	
					else {	
						pfor_compress( (int_type*)d + new_offset, (mCount - partition_recs*p)*int_size, str, h_columns_int[type_index[i]], 0);
					};	
					new_offset = new_offset + partition_recs;
					total_segments++;	
				};
			}
			else {
				thrust::copy(h_columns_int[type_index[i]].begin() + offset, h_columns_int[type_index[i]].begin() + offset + mCount, d_col);
				pfor_compress( d, mCount*int_size, str, h_columns_int[type_index[i]], 0);
			};			
		}
		else if(type[i] == 1) {
			if(decimal[i]) {
				thrust::device_ptr<float_type> d_col((float_type*)d);
				if(!op_sort.empty()) {
					thrust::gather(permutation.begin(), permutation.end(), d_columns_float[type_index[i]].begin(), d_col);
					thrust::device_ptr<long long int> d_col_dec((long long int*)d);
					thrust::transform(d_col,d_col+mCount,d_col_dec, float_to_long());
					
					for(unsigned int p = 0; p < partition_count; p++) {
						str = file_name + "." + std::to_string(cols[i]);
						curr_file = str;
						str += "." + std::to_string(total_segments-1);
						if (p < partition_count - 1)
							pfor_compress( (int_type*)d + new_offset, partition_recs*float_size, str, h_columns_float[type_index[i]], 1);
						else	
							pfor_compress( (int_type*)d + new_offset, (mCount - partition_recs*p)*float_size, str, h_columns_float[type_index[i]], 1);
						new_offset = new_offset + partition_recs;
						total_segments++;	
					};					
				}
				else {
					thrust::copy(h_columns_float[type_index[i]].begin() + offset, h_columns_float[type_index[i]].begin() + offset + mCount, d_col);
					thrust::device_ptr<long long int> d_col_dec((long long int*)d);
					thrust::transform(d_col,d_col+mCount,d_col_dec, float_to_long());
					pfor_compress( d, mCount*float_size, str, h_columns_float[type_index[i]], 1);					
				};
			}
			else { // do not compress -- float
				thrust::device_ptr<float_type> d_col((float_type*)d);
				if(!op_sort.empty()) {
					thrust::gather(permutation.begin(), permutation.end(), d_columns_float[type_index[i]].begin(), d_col);
					thrust::copy(d_col, d_col+mRecCount, h_columns_float[type_index[i]].begin());
					for(unsigned int p = 0; p < partition_count; p++) {
						str = file_name + "." + std::to_string(cols[i]);
						curr_file = str;
						str += "." + std::to_string(total_segments-1);
						unsigned int curr_cnt;
						if (p < partition_count - 1)
							curr_cnt = partition_recs;
						else
							curr_cnt = mCount - partition_recs*p;
					
						fstream binary_file(str.c_str(),ios::out|ios::binary|fstream::app);
						binary_file.write((char *)&curr_cnt, 4);
						binary_file.write((char *)(h_columns_float[type_index[i]].data() + new_offset),curr_cnt*float_size);
						new_offset = new_offset + partition_recs;
						unsigned int comp_type = 3;
						binary_file.write((char *)&comp_type, 4);
						binary_file.close();
					};					
				}
				else {
					fstream binary_file(str.c_str(),ios::out|ios::binary|fstream::app);
					binary_file.write((char *)&mCount, 4);
					binary_file.write((char *)(h_columns_float[type_index[i]].data() + offset),mCount*float_size);
					unsigned int comp_type = 3;
					binary_file.write((char *)&comp_type, 4);
					binary_file.close();				
				};
			};
		}
		else { //char
			if(!op_sort.empty()) {
				unsigned int*  h_permutation = new unsigned int[mRecCount];
				thrust::copy(permutation.begin(), permutation.end(), h_permutation);
				char* t = new char[char_size[type_index[i]]*mRecCount];
				apply_permutation_char_host(h_columns_char[type_index[i]], h_permutation, mRecCount, t, char_size[type_index[i]]);
				thrust::copy(t, t+ char_size[type_index[i]]*mRecCount, h_columns_char[type_index[i]]);
				delete [] t;
				for(unsigned int p = 0; p < partition_count; p++) {		
					str = file_name + "." + std::to_string(cols[i]);
					curr_file = str;
					str += "." + std::to_string(total_segments-1);
				
					if (p < partition_count - 1)
						compress_char(str, i, partition_recs, new_offset);
					else	
						compress_char(str, i, mCount - partition_recs*p, new_offset);
					new_offset = new_offset + partition_recs;
					total_segments++;	
				};	
			}
			else
				compress_char(str, i, mCount, offset);
		};

		if(check_type == 1) {
			if(fact_file_loaded) {
				writeHeader(file_name, cols[i], total_segments-1);
			}
		}
		else {
			if(check_val == 0) {
				writeHeader(file_name, cols[i], total_segments-1);
			};
		};
		total_segments = old_segments;
    };

	if(!op_sort.empty()) {
		total_segments = (old_segments-1)+partition_count;
	};	
    permutation.resize(0);
    permutation.shrink_to_fit();	
}


void CudaSet::writeHeader(string file_name, unsigned int col, unsigned int tot_segs) {
    string str = file_name + "." + std::to_string(col);
    string ff = str;
    str += ".header";
	
    fstream binary_file(str.c_str(),ios::out|ios::binary|ios::app);
    binary_file.write((char *)&total_count, 8);
    binary_file.write((char *)&tot_segs, 4);
    binary_file.write((char *)&total_max, 4);
    binary_file.write((char *)&cnt_counts[ff], 4);
    binary_file.close();
};


void CudaSet::writeSortHeader(string file_name)
{
    string str(file_name);
    unsigned int idx;

    if(!op_sort.empty()) {
        str += ".sort";
        fstream binary_file(str.c_str(),ios::out|ios::binary|ios::app);
        idx = (unsigned int)op_sort.size();
        binary_file.write((char *)&idx, 4);
        queue<string> os(op_sort);
        while(!os.empty()) {
            idx = columnNames[os.front()];
            binary_file.write((char *)&idx, 4);
            os.pop();
        };
        binary_file.close();
    }
    else if(!op_presort.empty()) {
        str += ".presort";
        fstream binary_file(str.c_str(),ios::out|ios::binary|ios::app);
        idx = (unsigned int)op_presort.size();
        binary_file.write((char *)&idx, 4);
        queue<string> os(op_presort);
        while(!os.empty()) {
            idx = columnNames[os.front()];
            binary_file.write((char *)&idx, 4);
            os.pop();
        };
        binary_file.close();
    };
}



void CudaSet::Store(string file_name, char* sep, unsigned int limit, bool binary )
{
    if (mRecCount == 0 && binary == 1) { // write tails
        for(unsigned int i = 0; i< mColumnCount; i++) {
            writeHeader(file_name, cols[i], total_segments);
        };
        return;
    };

    size_t mCount;

    if(limit != 0 && limit < mRecCount)
        mCount = limit;
    else {
        mCount = mRecCount;
	};	

    if(binary == 0) {

        char buffer [33];		
        queue<string> op_vx;
        for (auto it=columnNames.begin() ; it != columnNames.end(); ++it )
            op_vx.push((*it).first);
        curr_segment = 1000000;
        FILE *file_pr = fopen(file_name.c_str(), "w");
        if (file_pr  == NULL)
            cout << "Could not open file " << file_name << endl;


        if(prm_d.size() || source)
            allocColumns(this, op_vx);
        unsigned int curr_seg = 0;
        size_t cnt = 0;
        size_t curr_count, sum_printed = 0;
        while(sum_printed < mCount) {

            if(prm_d.size() || source)  {
                copyColumns(this, op_vx, curr_seg, cnt);
                // if host arrays are empty
                size_t olRecs = mRecCount;
                resize(mRecCount);
                mRecCount = olRecs;
                CopyToHost(0,mRecCount);
                if(sum_printed + mRecCount <= mCount)
                    curr_count = mRecCount;
                else {
                    curr_count = mCount - sum_printed;
                };
            }
            else
                curr_count = mCount;

            sum_printed = sum_printed + mRecCount;
            string ss;

            for(unsigned int i=0; i < curr_count; i++) {
                for(unsigned int j=0; j < mColumnCount; j++) {
                    if (type[j] == 0) {
                        sprintf(buffer, "%lld", (h_columns_int[type_index[j]])[i] );
                        fputs(buffer,file_pr);
                        fputs(sep, file_pr);
                    }
                    else if (type[j] == 1) {
                        sprintf(buffer, "%.2f", (h_columns_float[type_index[j]])[i] );
                        fputs(buffer,file_pr);
                        fputs(sep, file_pr);
                    }
                    else {
                        ss.assign(h_columns_char[type_index[j]] + (i*char_size[type_index[j]]), char_size[type_index[j]]);
                        trim(ss);
                        fputs(ss.c_str(), file_pr);
                        fputs(sep, file_pr);
                    };
                };
                if (i != mCount -1)
                    fputs("\n",file_pr);
            };
            curr_seg++;
        };
        fclose(file_pr);
    }
    else if(text_source) {  //writing a binary file using a text file as a source

        void* d;
        CUDA_SAFE_CALL(cudaMalloc((void **) &d, mCount*float_size));	
		
		compress(file_name, 0, 1, 0, d, mCount);
		
        if(write_sh) {
            writeSortHeader(file_name);
            write_sh = 0;
        };

        for(unsigned int i = 0; i< mColumnCount; i++)
            if(type[i] == 2)
                deAllocColumnOnDevice(i);
        cudaFree(d);
    }
    else { //writing a binary file using a binary file as a source
        fact_file_loaded = 1;
        size_t offset = 0;

        void* d;
        if(mRecCount < process_count) {
            CUDA_SAFE_CALL(cudaMalloc((void **) &d, mRecCount*float_size));
        }
        else {
            CUDA_SAFE_CALL(cudaMalloc((void **) &d, process_count*float_size));
        };


        if(!not_compressed) { // records are compressed, for example after filter op.
            //decompress to host
            queue<string> op_vx;
            for (auto it=columnNames.begin() ; it != columnNames.end(); ++it ) {
                op_vx.push((*it).first);
            };

            allocColumns(this, op_vx);
            size_t oldCnt = mRecCount;
            mRecCount = 0;
            resize(oldCnt);
            mRecCount = oldCnt;
            for(unsigned int i = 0; i < segCount; i++) {
                size_t cnt = 0;
                copyColumns(this, op_vx, i, cnt);
                reset_offsets();
                CopyToHost(0, mRecCount);
                offset = offset + mRecCount;
                compress(file_name, 0, 0, i - (segCount-1), d, mRecCount);
            };
        }
        else {
            // now we have decompressed records on the host
            //call setSegments and compress columns in every segment

            segCount = (mRecCount/process_count + 1);
            offset = 0;

            for(unsigned int z = 0; z < segCount; z++) {

                if(z < segCount-1) {
                    if(mRecCount < process_count) {
                        mCount = mRecCount;
                    }
                    else {
                        mCount = process_count;
                    }
                }
                else
                    mCount = mRecCount - (segCount-1)*process_count;

                compress(file_name, offset, 0, z - (segCount-1), d, mCount);
                offset = offset + mCount;
            };
            cudaFree(d);
        };
    };
}


void CudaSet::compress_char(string file_name, unsigned int index, size_t mCount, size_t offset)
{
    std::map<string,unsigned int> dict;
    std::vector<string> dict_ordered;
    std::vector<unsigned int> dict_val;
    map<string,unsigned int>::iterator iter;
    unsigned int bits_encoded;
    char* field;
    unsigned int len = char_size[type_index[index]];

    field = new char[len];

    for (unsigned int i = 0 ; i < mCount; i++) {

        strncpy(field, h_columns_char[type_index[index]] + (i+offset)*len, char_size[type_index[index]]);

        if((iter = dict.find(field)) != dict.end()) {
            dict_val.push_back(iter->second);
        }
        else {
            string f = field;
            dict[f] = (unsigned int)dict.size();
            dict_val.push_back((unsigned int)dict.size()-1);
            dict_ordered.push_back(f);
        };
    };
    delete [] field;

    bits_encoded = (unsigned int)ceil(log2(double(dict.size()+1)));

    char *cc = new char[len+1];
    unsigned int sz = (unsigned int)dict_ordered.size();
    // write to a file
    fstream binary_file(file_name.c_str(),ios::out|ios::binary);
    binary_file.write((char *)&sz, 4);
    for(unsigned int i = 0; i < dict_ordered.size(); i++) {
        memset(&cc[0], 0, len);
        strcpy(cc,dict_ordered[i].c_str());
        binary_file.write(cc, len);
    };

    delete [] cc;
    unsigned int fit_count = 64/bits_encoded;
    unsigned long long int val = 0;
    binary_file.write((char *)&fit_count, 4);
    binary_file.write((char *)&bits_encoded, 4);
    unsigned int curr_cnt = 1;
    unsigned int vals_count = (unsigned int)dict_val.size()/fit_count;
    if(!vals_count || dict_val.size()%fit_count)
        vals_count++;
    binary_file.write((char *)&vals_count, 4);
    unsigned int real_count = (unsigned int)dict_val.size();
    binary_file.write((char *)&real_count, 4);

    for(unsigned int i = 0; i < dict_val.size(); i++) {

        val = val | dict_val[i];

        if(curr_cnt < fit_count)
            val = val << bits_encoded;

        if( (curr_cnt == fit_count) || (i == (dict_val.size() - 1)) ) {
            if (curr_cnt < fit_count) {
                val = val << ((fit_count-curr_cnt)-1)*bits_encoded;
            };
            curr_cnt = 1;
            binary_file.write((char *)&val, 8);
            val = 0;
        }
        else
            curr_cnt = curr_cnt + 1;
    };
    binary_file.close();
};




bool CudaSet::LoadBigFile(const string file_name, const char* sep)
{
    char line[1000];
    unsigned int current_column, count = 0, index;
    char *p,*t;

    if (file_p == NULL)
        file_p = fopen(file_name.c_str(), "r");
    if (file_p  == NULL) {
        cout << "Could not open file " << file_name << endl;
        exit(0);
    };

    map<unsigned int,unsigned int> col_map;
    for(unsigned int i = 0; i < mColumnCount; i++) {
        col_map[cols[i]] = i;
    };

    while (count < process_count && fgets(line, 1000, file_p) != NULL) {
        strtok(line, "\n");
        current_column = 0;

        for(t=mystrtok(&p,line,'|'); t; t=mystrtok(&p,0,'|')) {
            current_column++;
            if(col_map.find(current_column) == col_map.end()) {
                continue;
            };

            index = col_map[current_column];
            if (type[index] == 0) {
                if (strchr(t,'-') == NULL) {
                    (h_columns_int[type_index[index]])[count] = atoll(t);
                }
                else {   // handling possible dates
                    strncpy(t+4,t+5,2);
                    strncpy(t+6,t+8,2);
                    t[8] = '\0';
                    (h_columns_int[type_index[index]])[count] = atoll(t);
                };
            }
            else if (type[index] == 1) {
                (h_columns_float[type_index[index]])[count] = atoff(t);
            }
            else  {//char
                strcpy(h_columns_char[type_index[index]] + count*char_size[type_index[index]], t);
            }
        };
        count++;
    };

    mRecCount = count;

    if(count < process_count)  {
        fclose(file_p);
        return 1;
    }
    else
        return 0;
};


void CudaSet::free()  {

    if (!seq)
        delete seq;

    for(unsigned int i = 0; i < mColumnCount; i++ ) {
        if(type[i] == 2 && h_columns_char[type_index[i]] && prm_d.size() == 0) {
            delete [] h_columns_char[type_index[i]];
            h_columns_char[type_index[i]] = NULL;
        }
        else {
            if(type[i] == 0 ) {
                h_columns_int[type_index[i]].resize(0);
                h_columns_int[type_index[i]].shrink_to_fit();
            }
            else if(type[i] == 1) {
                h_columns_float[type_index[i]].resize(0);
                h_columns_float[type_index[i]].shrink_to_fit();
            };
        }
    }


    if(filtered) { // free the sources
        string some_field;
        auto it=columnNames.begin();
        some_field = (*it).first;
        CudaSet* t = varNames[setMap[some_field]];
        t->deAllocOnDevice();
    };

    delete type;
    delete cols;

    if(!columnGroups.empty() && mRecCount !=0 && grp != NULL)
        cudaFree(grp);
};


bool* CudaSet::logical_and(bool* column1, bool* column2)
{
    thrust::device_ptr<bool> dev_ptr1(column1);
    thrust::device_ptr<bool> dev_ptr2(column2);

    thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, dev_ptr1, thrust::logical_and<bool>());

    thrust::device_free(dev_ptr2);
    return column1;
}


bool* CudaSet::logical_or(bool* column1, bool* column2)
{

    thrust::device_ptr<bool> dev_ptr1(column1);
    thrust::device_ptr<bool> dev_ptr2(column2);

    thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, dev_ptr1, thrust::logical_or<bool>());
    thrust::device_free(dev_ptr2);
    return column1;
}



bool* CudaSet::compare(int_type s, int_type d, int_type op_type)
{
    bool res;

    if (op_type == 2) // >
        if(d>s) res = 1;
        else res = 0;
    else if (op_type == 1)  // <
        if(d<s) res = 1;
        else res = 0;
    else if (op_type == 6) // >=
        if(d>=s) res = 1;
        else res = 0;
    else if (op_type == 5)  // <=
        if(d<=s) res = 1;
        else res = 0;
    else if (op_type == 4)// =
        if(d==s) res = 1;
        else res = 0;
    else // !=
        if(d!=s) res = 1;
        else res = 0;

    thrust::device_ptr<bool> p = thrust::device_malloc<bool>(mRecCount);
    thrust::sequence(p, p+mRecCount,res,(bool)0);

    return thrust::raw_pointer_cast(p);
};


bool* CudaSet::compare(float_type s, float_type d, int_type op_type)
{
    bool res;

    if (op_type == 2) // >
        if ((d-s) > EPSILON) res = 1;
        else res = 0;
    else if (op_type == 1)  // <
        if ((s-d) > EPSILON) res = 1;
        else res = 0;
    else if (op_type == 6) // >=
        if (((d-s) > EPSILON) || (((d-s) < EPSILON) && ((d-s) > -EPSILON))) res = 1;
        else res = 0;
    else if (op_type == 5)  // <=
        if (((s-d) > EPSILON) || (((d-s) < EPSILON) && ((d-s) > -EPSILON))) res = 1;
        else res = 0;
    else if (op_type == 4)// =
        if (((d-s) < EPSILON) && ((d-s) > -EPSILON)) res = 1;
        else res = 0;
    else // !=
        if (!(((d-s) < EPSILON) && ((d-s) > -EPSILON))) res = 1;
        else res = 0;

    thrust::device_ptr<bool> p = thrust::device_malloc<bool>(mRecCount);
    thrust::sequence(p, p+mRecCount,res,(bool)0);

    return thrust::raw_pointer_cast(p);
}


bool* CudaSet::compare(int_type* column1, int_type d, int_type op_type)
{
    thrust::device_ptr<bool> temp = thrust::device_malloc<bool>(mRecCount);
    thrust::device_ptr<int_type> dev_ptr(column1);


    if (op_type == 2) // >
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), temp, thrust::greater<int_type>());
    else if (op_type == 1)  // <
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), temp, thrust::less<int_type>());
    else if (op_type == 6) // >=
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), temp, thrust::greater_equal<int_type>());
    else if (op_type == 5)  // <=
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), temp, thrust::less_equal<int_type>());
    else if (op_type == 4)// =
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), temp, thrust::equal_to<int_type>());
    else // !=
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), temp, thrust::not_equal_to<int_type>());

    return thrust::raw_pointer_cast(temp);

}

bool* CudaSet::compare(float_type* column1, float_type d, int_type op_type)
{
    thrust::device_ptr<bool> res = thrust::device_malloc<bool>(mRecCount);
    thrust::device_ptr<float_type> dev_ptr(column1);

    if (op_type == 2) // >
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), res, f_greater());
    else if (op_type == 1)  // <
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), res, f_less());
    else if (op_type == 6) // >=
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), res, f_greater_equal_to());
    else if (op_type == 5)  // <=
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), res, f_less_equal());
    else if (op_type == 4)// =
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), res, f_equal_to());
    else // !=
        thrust::transform(dev_ptr, dev_ptr+mRecCount, thrust::make_constant_iterator(d), res, f_not_equal_to());

    return thrust::raw_pointer_cast(res);
}


bool* CudaSet::compare(int_type* column1, int_type* column2, int_type op_type)
{
    thrust::device_ptr<int_type> dev_ptr1(column1);
    thrust::device_ptr<int_type> dev_ptr2(column2);
    thrust::device_ptr<bool> temp = thrust::device_malloc<bool>(mRecCount);

    if (op_type == 2) // >
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::greater<int_type>());
    else if (op_type == 1)  // <
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::less<int_type>());
    else if (op_type == 6) // >=
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::greater_equal<int_type>());
    else if (op_type == 5)  // <=
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::less_equal<int_type>());
    else if (op_type == 4)// =
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::equal_to<int_type>());
    else // !=
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::not_equal_to<int_type>());

    return thrust::raw_pointer_cast(temp);
}

bool* CudaSet::compare(float_type* column1, float_type* column2, int_type op_type)
{
    thrust::device_ptr<float_type> dev_ptr1(column1);
    thrust::device_ptr<float_type> dev_ptr2(column2);
    thrust::device_ptr<bool> temp = thrust::device_malloc<bool>(mRecCount);

    if (op_type == 2) // >
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_greater());
    else if (op_type == 1)  // <
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_less());
    else if (op_type == 6) // >=
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_greater_equal_to());
    else if (op_type == 5)  // <=
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_less_equal());
    else if (op_type == 4)// =
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_equal_to());
    else // !=
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_not_equal_to());

    return thrust::raw_pointer_cast(temp);

}


bool* CudaSet::compare(float_type* column1, int_type* column2, int_type op_type)
{
    thrust::device_ptr<float_type> dev_ptr1(column1);
    thrust::device_ptr<int_type> dev_ptr(column2);
    thrust::device_ptr<float_type> dev_ptr2 = thrust::device_malloc<float_type>(mRecCount);
    thrust::device_ptr<bool> temp = thrust::device_malloc<bool>(mRecCount);

    thrust::transform(dev_ptr, dev_ptr + mRecCount, dev_ptr2, long_to_float_type());

    if (op_type == 2) // >
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_greater());
    else if (op_type == 1)  // <
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_less());
    else if (op_type == 6) // >=
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_greater_equal_to());
    else if (op_type == 5)  // <=
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_less_equal());
    else if (op_type == 4)// =
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_equal_to());
    else // !=
        thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, f_not_equal_to());

    thrust::device_free(dev_ptr2);
    return thrust::raw_pointer_cast(temp);
}


float_type* CudaSet::op(int_type* column1, float_type* column2, string op_type, int reverse)
{

    thrust::device_ptr<float_type> temp = thrust::device_malloc<float_type>(mRecCount);
    thrust::device_ptr<int_type> dev_ptr(column1);

    thrust::transform(dev_ptr, dev_ptr + mRecCount, temp, long_to_float_type()); // in-place transformation

    thrust::device_ptr<float_type> dev_ptr1(column2);

    if(reverse == 0) {
        if (op_type.compare("MUL") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::multiplies<float_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::plus<float_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::minus<float_type>());
        else
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::divides<float_type>());
    }
    else {
        if (op_type.compare("MUL") == 0)
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::multiplies<float_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::plus<float_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::minus<float_type>());
        else
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::divides<float_type>());

    };

    return thrust::raw_pointer_cast(temp);

}




int_type* CudaSet::op(int_type* column1, int_type* column2, string op_type, int reverse)
{

    thrust::device_ptr<int_type> temp = thrust::device_malloc<int_type>(mRecCount);
    thrust::device_ptr<int_type> dev_ptr1(column1);
    thrust::device_ptr<int_type> dev_ptr2(column2);

    if(reverse == 0) {
        if (op_type.compare("MUL") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::multiplies<int_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::plus<int_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::minus<int_type>());
        else
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::divides<int_type>());
    }
    else  {
        if (op_type.compare("MUL") == 0)
            thrust::transform(dev_ptr2, dev_ptr2+mRecCount, dev_ptr1, temp, thrust::multiplies<int_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(dev_ptr2, dev_ptr2+mRecCount, dev_ptr1, temp, thrust::plus<int_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(dev_ptr2, dev_ptr2+mRecCount, dev_ptr1, temp, thrust::minus<int_type>());
        else
            thrust::transform(dev_ptr2, dev_ptr2+mRecCount, dev_ptr1, temp, thrust::divides<int_type>());
    }

    return thrust::raw_pointer_cast(temp);

}

float_type* CudaSet::op(float_type* column1, float_type* column2, string op_type, int reverse)
{

    thrust::device_ptr<float_type> temp = thrust::device_malloc<float_type>(mRecCount);
    thrust::device_ptr<float_type> dev_ptr1(column1);
    thrust::device_ptr<float_type> dev_ptr2(column2);

    if(reverse == 0) {
        if (op_type.compare("MUL") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::multiplies<float_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::plus<float_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::minus<float_type>());
        else
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, dev_ptr2, temp, thrust::divides<float_type>());
    }
    else {
        if (op_type.compare("MUL") == 0)
            thrust::transform(dev_ptr2, dev_ptr2+mRecCount, dev_ptr1, temp, thrust::multiplies<float_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(dev_ptr2, dev_ptr2+mRecCount, dev_ptr1, temp, thrust::plus<float_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(dev_ptr2, dev_ptr2+mRecCount, dev_ptr1, temp, thrust::minus<float_type>());
        else
            thrust::transform(dev_ptr2, dev_ptr2+mRecCount, dev_ptr1, temp, thrust::divides<float_type>());
    };
    return thrust::raw_pointer_cast(temp);
}

int_type* CudaSet::op(int_type* column1, int_type d, string op_type, int reverse)
{
    thrust::device_ptr<int_type> temp = thrust::device_malloc<int_type>(mRecCount);
    thrust::fill(temp, temp+mRecCount, d);

    thrust::device_ptr<int_type> dev_ptr1(column1);

    if(reverse == 0) {
        if (op_type.compare("MUL") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::multiplies<int_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::plus<int_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::minus<int_type>());
        else
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::divides<int_type>());
    }
    else {
        if (op_type.compare("MUL") == 0)
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::multiplies<int_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::plus<int_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::minus<int_type>());
        else
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::divides<int_type>());
    };
    return thrust::raw_pointer_cast(temp);
}

float_type* CudaSet::op(int_type* column1, float_type d, string op_type, int reverse)
{
    thrust::device_ptr<float_type> temp = thrust::device_malloc<float_type>(mRecCount);
    thrust::fill(temp, temp+mRecCount, d);

    thrust::device_ptr<int_type> dev_ptr(column1);
    thrust::device_ptr<float_type> dev_ptr1 = thrust::device_malloc<float_type>(mRecCount);
    thrust::transform(dev_ptr, dev_ptr + mRecCount, dev_ptr1, long_to_float_type());

    if(reverse == 0) {
        if (op_type.compare("MUL") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::multiplies<float_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::plus<float_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::minus<float_type>());
        else
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, temp, temp, thrust::divides<float_type>());
    }
    else  {
        if (op_type.compare("MUL") == 0)
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::multiplies<float_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::plus<float_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::minus<float_type>());
        else
            thrust::transform(temp, temp+mRecCount, dev_ptr1, temp, thrust::divides<float_type>());

    };
    thrust::device_free(dev_ptr1);
    return thrust::raw_pointer_cast(temp);
}


float_type* CudaSet::op(float_type* column1, float_type d, string op_type,int reverse)
{
    thrust::device_ptr<float_type> temp = thrust::device_malloc<float_type>(mRecCount);
    thrust::device_ptr<float_type> dev_ptr1(column1);

    if(reverse == 0) {
        if (op_type.compare("MUL") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, thrust::make_constant_iterator(d), temp, thrust::multiplies<float_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, thrust::make_constant_iterator(d), temp, thrust::plus<float_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, thrust::make_constant_iterator(d), temp, thrust::minus<float_type>());
        else
            thrust::transform(dev_ptr1, dev_ptr1+mRecCount, thrust::make_constant_iterator(d), temp, thrust::divides<float_type>());
    }
    else	{
        if (op_type.compare("MUL") == 0)
            thrust::transform(thrust::make_constant_iterator(d), thrust::make_constant_iterator(d)+mRecCount, dev_ptr1, temp, thrust::multiplies<float_type>());
        else if (op_type.compare("ADD") == 0)
            thrust::transform(thrust::make_constant_iterator(d), thrust::make_constant_iterator(d)+mRecCount, dev_ptr1, temp, thrust::plus<float_type>());
        else if (op_type.compare("MINUS") == 0)
            thrust::transform(thrust::make_constant_iterator(d), thrust::make_constant_iterator(d)+mRecCount, dev_ptr1, temp, thrust::minus<float_type>());
        else
            thrust::transform(thrust::make_constant_iterator(d), thrust::make_constant_iterator(d)+mRecCount, dev_ptr1, temp, thrust::divides<float_type>());

    };

    return thrust::raw_pointer_cast(temp);

}





void CudaSet::initialize(queue<string> &nameRef, queue<string> &typeRef, queue<int> &sizeRef, queue<int> &colsRef, size_t Recs, string file_name) // compressed data for DIM tables
{
    mColumnCount = (unsigned int)nameRef.size();
    type = new unsigned int[mColumnCount];
    cols = new unsigned int[mColumnCount];
    decimal = new bool[mColumnCount];
    unsigned int cnt;
    file_p = NULL;
    FILE* f;
    string f1;

    prealloc_char_size = 0;
    not_compressed = 0;
    mRecCount = Recs;
    hostRecCount = Recs;
    load_file_name = file_name;

    f1 = file_name + ".sort";
    f = fopen (f1.c_str() , "rb" );
    if(f != NULL) {
        unsigned int sz, idx;
        fread((char *)&sz, 4, 1, f);
        for(unsigned int j = 0; j < sz; j++) {
            fread((char *)&idx, 4, 1, f);
            sorted_fields.push(idx);
            cout << "segment sorted on " << idx << endl;
        };
        fclose(f);
    };

    f1 = file_name + ".presort";
    f = fopen (f1.c_str() , "rb" );
    if(f != NULL) {
        unsigned int sz, idx;
        fread((char *)&sz, 4, 1, f);
        for(unsigned int j = 0; j < sz; j++) {
            fread((char *)&idx, 4, 1, f);
            presorted_fields.push(idx);
            cout << "presorted on " << idx << endl;
        };
        fclose(f);
    };


    tmp_table = 0;
    filtered = 0;

    for(unsigned int i=0; i < mColumnCount; i++) {

        columnNames[nameRef.front()] = i;
        cols[i] = colsRef.front();
        seq = 0;

        f1 = file_name + "." + std::to_string(colsRef.front()) + ".header";
        f = fopen (f1.c_str() , "rb" );
        for(unsigned int j = 0; j < 5; j++)
            fread((char *)&cnt, 4, 1, f);
        fclose(f);
        //cout << "creating " << f1 << " " << cnt << endl;

        if ((typeRef.front()).compare("int") == 0) {
            type[i] = 0;
            decimal[i] = 0;
            h_columns_int.push_back(thrust::host_vector<int_type, pinned_allocator<int_type> >(cnt + 9));
            d_columns_int.push_back(thrust::device_vector<int_type>());
            type_index[i] = h_columns_int.size()-1;
        }
        else if ((typeRef.front()).compare("float") == 0) {
            type[i] = 1;
            decimal[i] = 0;
            h_columns_float.push_back(thrust::host_vector<float_type, pinned_allocator<float_type> >(cnt + 9));
            d_columns_float.push_back(thrust::device_vector<float_type >());
            type_index[i] = h_columns_float.size()-1;
        }
        else if ((typeRef.front()).compare("decimal") == 0) {
            type[i] = 1;
            decimal[i] = 1;
            h_columns_float.push_back(thrust::host_vector<float_type, pinned_allocator<float_type> >(cnt + 9));
            d_columns_float.push_back(thrust::device_vector<float_type>());
            type_index[i] = h_columns_float.size()-1;
        }
        else {
            type[i] = 2;
            decimal[i] = 0;
            h_columns_char.push_back(NULL);
            d_columns_char.push_back(NULL);
            char_size.push_back(sizeRef.front());
            type_index[i] = h_columns_char.size()-1;
        };

        nameRef.pop();
        typeRef.pop();
        sizeRef.pop();
        colsRef.pop();
    };
};



void CudaSet::initialize(queue<string> &nameRef, queue<string> &typeRef, queue<int> &sizeRef, queue<int> &colsRef, size_t Recs)
{
    mColumnCount = (unsigned int)nameRef.size();
    type = new unsigned int[mColumnCount];
    cols = new unsigned int[mColumnCount];
    decimal = new bool[mColumnCount];
    prealloc_char_size = 0;

    file_p = NULL;
    tmp_table = 0;
    filtered = 0;

    mRecCount = Recs;
    hostRecCount = Recs;
    segCount = 1;

    for(unsigned int i=0; i < mColumnCount; i++) {

        columnNames[nameRef.front()] = i;
        cols[i] = colsRef.front();
        seq = 0;

        if ((typeRef.front()).compare("int") == 0) {
            type[i] = 0;
            decimal[i] = 0;
            h_columns_int.push_back(thrust::host_vector<int_type, pinned_allocator<int_type> >());
            d_columns_int.push_back(thrust::device_vector<int_type>());
            type_index[i] = h_columns_int.size()-1;
        }
        else if ((typeRef.front()).compare("float") == 0) {
            type[i] = 1;
            decimal[i] = 0;
            h_columns_float.push_back(thrust::host_vector<float_type, pinned_allocator<float_type> >());
            d_columns_float.push_back(thrust::device_vector<float_type>());
            type_index[i] = h_columns_float.size()-1;
        }
        else if ((typeRef.front()).compare("decimal") == 0) {
            type[i] = 1;
            decimal[i] = 1;
            h_columns_float.push_back(thrust::host_vector<float_type, pinned_allocator<float_type> >());
            d_columns_float.push_back(thrust::device_vector<float_type>());
            type_index[i] = h_columns_float.size()-1;
        }

        else {
            type[i] = 2;
            decimal[i] = 0;
            h_columns_char.push_back(NULL);
            d_columns_char.push_back(NULL);
            char_size.push_back(sizeRef.front());
            type_index[i] = h_columns_char.size()-1;
        };
        nameRef.pop();
        typeRef.pop();
        sizeRef.pop();
        colsRef.pop();
    };
};

void CudaSet::initialize(size_t RecordCount, unsigned int ColumnCount)
{
    mRecCount = RecordCount;
    hostRecCount = RecordCount;
    mColumnCount = ColumnCount;
    prealloc_char_size = 0;

    type = new unsigned int[mColumnCount];
    cols = new unsigned int[mColumnCount];
    decimal = new bool[mColumnCount];
    seq = 0;
    filtered = 0;

    for(unsigned int i =0; i < mColumnCount; i++) {
        cols[i] = i;
    };


};


void CudaSet::initialize(queue<string> op_sel, queue<string> op_sel_as)
{
    mRecCount = 0;
    mColumnCount = (unsigned int)op_sel.size();

    type = new unsigned int[mColumnCount];
    cols = new unsigned int[mColumnCount];
    decimal = new bool[mColumnCount];

    seq = 0;
    segCount = 1;
    not_compressed = 1;
    filtered = 0;
    col_aliases = op_sel_as;
    prealloc_char_size = 0;

    unsigned int index;
    unsigned int i = 0;
    while(!op_sel.empty()) {

        if(!setMap.count(op_sel.front())) {
            cout << "coudn't find column " << op_sel.front() << endl;
            exit(0);
        };


        CudaSet* a = varNames[setMap[op_sel.front()]];

        if(i == 0)
            maxRecs = a->maxRecs;

        index = a->columnNames[op_sel.front()];
        cols[i] = i;
        decimal[i] = a->decimal[i];
        columnNames[op_sel.front()] = i;

        if (a->type[index] == 0)  {
            d_columns_int.push_back(thrust::device_vector<int_type>());
            h_columns_int.push_back(thrust::host_vector<int_type, pinned_allocator<int_type> >());
            type[i] = 0;
            type_index[i] = h_columns_int.size()-1;
        }
        else if ((a->type)[index] == 1) {
            d_columns_float.push_back(thrust::device_vector<float_type>());
            h_columns_float.push_back(thrust::host_vector<float_type, pinned_allocator<float_type> >());
            type[i] = 1;
            type_index[i] = h_columns_float.size()-1;
        }
        else {
            h_columns_char.push_back(NULL);
            d_columns_char.push_back(NULL);
            type[i] = 2;
            type_index[i] = h_columns_char.size()-1;
            char_size.push_back(a->char_size[a->type_index[index]]);
        };
        i++;
        op_sel.pop();
    };

}


void CudaSet::initialize(CudaSet* a, CudaSet* b, queue<string> op_sel, queue<string> op_sel_as)
{
    mRecCount = 0;
    mColumnCount = 0;
    queue<string> q_cnt(op_sel);
    unsigned int i = 0;
    set<string> field_names;
    while(!q_cnt.empty()) {
        if(a->columnNames.find(q_cnt.front()) !=  a->columnNames.end() || b->columnNames.find(q_cnt.front()) !=  b->columnNames.end())  {
            field_names.insert(q_cnt.front());
        };
        q_cnt.pop();
    }
    mColumnCount = (unsigned int)field_names.size();

    type = new unsigned int[mColumnCount];
    cols = new unsigned int[mColumnCount];
    decimal = new bool[mColumnCount];
    maxRecs = b->maxRecs;

    map<string,unsigned int>::iterator it;
    seq = 0;

    segCount = 1;
    filtered = 0;
    not_compressed = 1;

    col_aliases = op_sel_as;
    prealloc_char_size = 0;

    unsigned int index;
    i = 0;
    while(!op_sel.empty() && (columnNames.find(op_sel.front()) ==  columnNames.end())) {

        if((it = a->columnNames.find(op_sel.front())) !=  a->columnNames.end()) {
            index = it->second;
            cols[i] = i;
            decimal[i] = a->decimal[i];
            columnNames[op_sel.front()] = i;

            if (a->type[index] == 0)  {
                d_columns_int.push_back(thrust::device_vector<int_type>());
                h_columns_int.push_back(thrust::host_vector<int_type, pinned_allocator<int_type> >());
                type[i] = 0;
                type_index[i] = h_columns_int.size()-1;
            }
            else if ((a->type)[index] == 1) {
                d_columns_float.push_back(thrust::device_vector<float_type>());
                h_columns_float.push_back(thrust::host_vector<float_type, pinned_allocator<float_type> >());
                type[i] = 1;
                type_index[i] = h_columns_float.size()-1;
            }
            else {
                h_columns_char.push_back(NULL);
                d_columns_char.push_back(NULL);
                type[i] = 2;
                type_index[i] = h_columns_char.size()-1;
                char_size.push_back(a->char_size[a->type_index[index]]);
            };
            i++;
        }
        else if((it = b->columnNames.find(op_sel.front())) !=  b->columnNames.end()) {
            index = it->second;
            columnNames[op_sel.front()] = i;
            cols[i] = i;
            decimal[i] = b->decimal[index];

            if ((b->type)[index] == 0) {
                d_columns_int.push_back(thrust::device_vector<int_type>());
                h_columns_int.push_back(thrust::host_vector<int_type, pinned_allocator<int_type> >());
                type[i] = 0;
                type_index[i] = h_columns_int.size()-1;
            }
            else if ((b->type)[index] == 1) {
                d_columns_float.push_back(thrust::device_vector<float_type>());
                h_columns_float.push_back(thrust::host_vector<float_type, pinned_allocator<float_type> >());
                type[i] = 1;
                type_index[i] = h_columns_float.size()-1;
            }
            else {
                h_columns_char.push_back(NULL);
                d_columns_char.push_back(NULL);
                type[i] = 2;
                type_index[i] = h_columns_char.size()-1;
                char_size.push_back(b->char_size[b->type_index[index]]);
            };
            i++;
        }
        op_sel.pop();
    };
};



int_type reverse_op(int_type op_type)
{
    if (op_type == 2) // >
        return 5;
    else if (op_type == 1)  // <
        return 6;
    else if (op_type == 6) // >=
        return 1;
    else if (op_type == 5)  // <=
        return 2;
    else return op_type;
}


size_t getFreeMem()
{
    size_t available, total;
    cudaMemGetInfo(&available, &total);
    return available;
} ;



void allocColumns(CudaSet* a, queue<string> fields)
{
    if(a->filtered) {
        size_t max_sz = max_tmp(a) ;
        CudaSet* t = varNames[setMap[fields.front()]];
        if(max_sz*t->maxRecs > alloced_sz) {
            if(alloced_sz) {
                cudaFree(alloced_tmp);
            };
            cudaMalloc((void **) &alloced_tmp, max_sz*t->maxRecs);
            alloced_sz = max_sz*t->maxRecs;
        }
    }
    else {

        while(!fields.empty()) {
            if(setMap.count(fields.front()) > 0) {

                unsigned int idx = a->columnNames[fields.front()];
                bool onDevice = 0;

                if(a->type[idx] == 0) {
                    if(a->d_columns_int[a->type_index[idx]].size() > 0) {
                        onDevice = 1;
                    }
                }
                else if(a->type[idx] == 1) {
                    if(a->d_columns_float[a->type_index[idx]].size() > 0) {
                        onDevice = 1;
                    };
                }
                else {
                    if((a->d_columns_char[a->type_index[idx]]) != NULL) {
                        onDevice = 1;
                    };
                };

                if (!onDevice) {
                    a->allocColumnOnDevice(idx, a->maxRecs);
                }
            }
            fields.pop();
        };
    };
}



void gatherColumns(CudaSet* a, CudaSet* t, string field, unsigned int segment, size_t& count)
{

    unsigned int tindex = t->columnNames[field];
    unsigned int idx = a->columnNames[field];

    if(!a->onDevice(idx)) {
        a->allocColumnOnDevice(idx, a->maxRecs);
    };

    if(a->prm_index == 'R') {
        mygather(tindex, idx, a, t, count, a->mRecCount);
    }
    else {
        mycopy(tindex, idx, a, t, count, t->mRecCount);
		a->mRecCount = t->mRecCount;
    };
    //a->mRecCount = a->prm_d.size();
}

size_t getSegmentRecCount(CudaSet* a, unsigned int segment) {
    if (segment == a->segCount-1) {
	    cout << "SEGREC " << a->hostRecCount << " " << a->maxRecs << " " << segment << endl;
        return a->hostRecCount - a->maxRecs*segment;
    }
    else
        return 	a->maxRecs;
}



void copyColumns(CudaSet* a, queue<string> fields, unsigned int segment, size_t& count, bool rsz, bool flt)
{
    set<string> uniques;
    CudaSet *t;

    if(a->filtered) { //filter the segment
        if(flt) {
            filter_op(a->fil_s, a->fil_f, segment);
        };
        if(rsz) {
            a->resizeDevice(count);
            a->devRecCount = count+a->mRecCount;
        };
    };


    while(!fields.empty()) {
        if (uniques.count(fields.front()) == 0 && setMap.count(fields.front()) > 0)	{
            if(a->filtered) {
                if(a->mRecCount) {
                    t = varNames[setMap[fields.front()]];
                    alloced_switch = 1;
                    t->CopyColumnToGpu(t->columnNames[fields.front()], segment);	
                    gatherColumns(a, t, fields.front(), segment, count);					
                    alloced_switch = 0;
                };
            }
            else {
                a->CopyColumnToGpu(a->columnNames[fields.front()], segment, count);
            };
            uniques.insert(fields.front());
        };
        fields.pop();
    };
}



void setPrm(CudaSet* a, CudaSet* b, char val, unsigned int segment) {

    b->prm_index = val;
    if (val == 'A') {
        b->mRecCount = getSegmentRecCount(a,segment);
    }
}



void mygather(unsigned int tindex, unsigned int idx, CudaSet* a, CudaSet* t, size_t offset, size_t g_size)
{
    if(t->type[tindex] == 0) {
        if(!alloced_switch) {
            thrust::gather(a->prm_d.begin(), a->prm_d.begin() + g_size,
                           t->d_columns_int[t->type_index[tindex]].begin(), a->d_columns_int[a->type_index[idx]].begin() + offset);
        }
        else {
            thrust::device_ptr<int_type> d_col((int_type*)alloced_tmp);
            thrust::gather(a->prm_d.begin(), a->prm_d.begin() + g_size,
                           d_col, a->d_columns_int[a->type_index[idx]].begin() + offset);
        };
    }
    else if(t->type[tindex] == 1) {
        if(!alloced_switch) {
            thrust::gather(a->prm_d.begin(), a->prm_d.begin() + g_size,
                           t->d_columns_float[t->type_index[tindex]].begin(), a->d_columns_float[a->type_index[idx]].begin() + offset);
        }
        else {
            thrust::device_ptr<float_type> d_col((float_type*)alloced_tmp);
            thrust::gather(a->prm_d.begin(), a->prm_d.begin() + g_size,
                           d_col, a->d_columns_float[a->type_index[idx]].begin() + offset);
        };
    }
    else {
        if(!alloced_switch) {

            str_gather((void*)thrust::raw_pointer_cast(a->prm_d.data()), g_size,
                       (void*)t->d_columns_char[t->type_index[tindex]], (void*)(a->d_columns_char[a->type_index[idx]] + offset*a->char_size[a->type_index[idx]]), (unsigned int)a->char_size[a->type_index[idx]] );

        }
        else {
            str_gather((void*)thrust::raw_pointer_cast(a->prm_d.data()), g_size,
                       alloced_tmp, (void*)(a->d_columns_char[a->type_index[idx]] + offset*a->char_size[a->type_index[idx]]), (unsigned int)a->char_size[a->type_index[idx]] );
        };
    }
};

void mycopy(unsigned int tindex, unsigned int idx, CudaSet* a, CudaSet* t, size_t offset, size_t g_size)
{
    if(t->type[tindex] == 0) {
        if(!alloced_switch) {
            thrust::copy(t->d_columns_int[t->type_index[tindex]].begin(), t->d_columns_int[t->type_index[tindex]].begin() + g_size,
                         a->d_columns_int[a->type_index[idx]].begin() + offset);
        }
        else {
            thrust::device_ptr<int_type> d_col((int_type*)alloced_tmp);
            thrust::copy(d_col, d_col + g_size, a->d_columns_int[a->type_index[idx]].begin() + offset);

        };
    }
    else if(t->type[tindex] == 1) {
        if(!alloced_switch) {
            thrust::copy(t->d_columns_float[t->type_index[tindex]].begin(), t->d_columns_float[t->type_index[tindex]].begin() + g_size,
                         a->d_columns_float[a->type_index[idx]].begin() + offset);
        }
        else {
            thrust::device_ptr<float_type> d_col((float_type*)alloced_tmp);
            thrust::copy(d_col, d_col + g_size,	a->d_columns_float[a->type_index[idx]].begin() + offset);
        };
    }
    else {
        if(!alloced_switch) {
            cudaMemcpy((void**)(a->d_columns_char[a->type_index[idx]] + offset*a->char_size[a->type_index[idx]]), (void**)t->d_columns_char[t->type_index[tindex]],
                       g_size*t->char_size[t->type_index[tindex]], cudaMemcpyDeviceToDevice);
        }
        else {
            cudaMemcpy((void**)(a->d_columns_char[a->type_index[idx]] + offset*a->char_size[a->type_index[idx]]), alloced_tmp,
                       g_size*t->char_size[t->type_index[tindex]], cudaMemcpyDeviceToDevice);
        };
    };
};



size_t load_queue(queue<string> c1, CudaSet* right, bool str_join, string f2, size_t &rcount,
                  unsigned int start_segment, unsigned int end_segment, bool rsz, bool flt)
{
    queue<string> cc;
    while(!c1.empty()) {
        if(right->columnNames.find(c1.front()) !=  right->columnNames.end()) {
            if(f2 != c1.front() || str_join) {
                cc.push(c1.front());
            };
        };
        c1.pop();
    };
    if(!str_join && right->columnNames.find(f2) !=  right->columnNames.end()) {
        cc.push(f2);
    };

    if(right->filtered) {
        allocColumns(right, cc);
        rcount = right->maxRecs;
    }
    else
        rcount = right->mRecCount;

    queue<string> ct(cc);
    reset_offsets();

    while(!ct.empty()) {
        if(right->filtered && rsz) {
            right->mRecCount = 0;
        }
        else {
            right->allocColumnOnDevice(right->columnNames[ct.front()], rcount);
		};	
        ct.pop();
    };


    size_t cnt_r = 0;
    for(unsigned int i = start_segment; i < end_segment; i++) {
        reset_offsets();
        if(!right->filtered)
            copyColumns(right, cc, i, cnt_r, rsz, 0);
        else
            copyColumns(right, cc, i, cnt_r, rsz, flt);
        cnt_r = cnt_r + right->mRecCount;
    };
    right->mRecCount = cnt_r;
    return cnt_r;

}

size_t max_char(CudaSet* a)
{
    size_t max_char1 = 0;
    for(unsigned int i = 0; i < a->char_size.size(); i++)
        if (a->char_size[i] > max_char1)
            max_char1 = a->char_size[i];

    return max_char1;
};

size_t max_char(CudaSet* a, set<string> field_names)
{
    size_t max_char1 = 0, i;
    for (auto it=field_names.begin(); it!=field_names.end(); ++it) {
        i = a->columnNames[*it];
        if (a->type[i] == 2) {
            if (a->char_size[a->type_index[i]] > max_char1)
                max_char1 = a->char_size[a->type_index[i]];
        };
    };
    return max_char1;
};

size_t max_char(CudaSet* a, queue<string> field_names)
{
    size_t max_char = 0, i;
    while (!field_names.empty()) {
        i = a->columnNames[field_names.front()];
        if (a->type[i] == 2) {
            if (a->char_size[a->type_index[i]] > max_char)
                max_char = a->char_size[a->type_index[i]];
        };
        field_names.pop();
    };
    return max_char;
};



size_t max_tmp(CudaSet* a)
{
    size_t max_sz = 0;
    for(unsigned int i = 0; i < a->mColumnCount; i++) {
        if(a->type[i] == 0) {
            if(int_size > max_sz)
                max_sz = int_size;
        }
        else if(a->type[i] == 1) {
            if(float_size > max_sz)
                max_sz = float_size;
        };
    };
    size_t m_char = max_char(a);
    if(m_char > max_sz)
        return m_char;
    else
        return max_sz;

};


void reset_offsets() {
    map<unsigned int, unsigned long long int>::iterator iter;

    for (iter = str_offset.begin(); iter != str_offset.end(); ++iter) {
        iter->second = 0;
    };

};

void setSegments(CudaSet* a, queue<string> cols)
{
    size_t mem_available = getFreeMem();
    size_t tot_sz = 0, idx;
    while(!cols.empty()) {
        idx = a->columnNames[cols.front()];
        if(a->type[idx] != 2)
            tot_sz = tot_sz + int_size;
        else
            tot_sz = tot_sz + a->char_size[a->type_index[idx]];
        cols.pop();
    };
    if(a->mRecCount*tot_sz > mem_available/3) { //default is 3
        a->segCount = (a->mRecCount*tot_sz)/(mem_available/5) + 1;
        a->maxRecs = (a->mRecCount/a->segCount)+1;
    };

};

void update_permutation_char(char* key, unsigned int* permutation, size_t RecCount, string SortType, char* tmp, unsigned int len)
{

    str_gather((void*)permutation, RecCount, (void*)key, (void*)tmp, len);

    // stable_sort the permuted keys and update the permutation
    if (SortType.compare("DESC") == 0 )
        str_sort(tmp, RecCount, permutation, 1, len);
    else
        str_sort(tmp, RecCount, permutation, 0, len);
}

void update_permutation_char_host(char* key, unsigned int* permutation, size_t RecCount, string SortType, char* tmp, unsigned int len)
{
    str_gather_host(permutation, RecCount, (void*)key, (void*)tmp, len);

    if (SortType.compare("DESC") == 0 )
        str_sort_host(tmp, RecCount, permutation, 1, len);
    else
        str_sort_host(tmp, RecCount, permutation, 0, len);

}



void apply_permutation_char(char* key, unsigned int* permutation, size_t RecCount, char* tmp, unsigned int len)
{
    // copy keys to temporary vector
    cudaMemcpy( (void*)tmp, (void*) key, RecCount*len, cudaMemcpyDeviceToDevice);
    // permute the keys
    str_gather((void*)permutation, RecCount, (void*)tmp, (void*)key, len);
}


void apply_permutation_char_host(char* key, unsigned int* permutation, size_t RecCount, char* res, unsigned int len)
{
    str_gather_host(permutation, RecCount, (void*)key, (void*)res, len);
}


void filter_op(char *s, char *f, unsigned int segment)
{
    CudaSet *a, *b;

    a = varNames.find(f)->second;
    a->name = f;
    //std::clock_t start1 = std::clock();
    //std::cout<< "filt disk time start " <<  (( tot ) / (double)CLOCKS_PER_SEC ) <<'\n';

    if(a->mRecCount == 0) {
        b = new CudaSet(0,1);
    }
    else {
        //cout << "FILTER " << s << " " << f << " " << getFreeMem() << endl;

        b = varNames[s];
        size_t cnt = 0;
        allocColumns(a, b->fil_value);

        if (b->prm_d.size() == 0)
            b->prm_d.resize(a->maxRecs);

        map_check = zone_map_check(b->fil_type,b->fil_value,b->fil_nums, b->fil_nums_f, a, segment);
        //cout << "MAP CHECK segment " << segment << " " << map_check <<  '\xd';
        //cout << "MAP CHECK segment " << segment << " " << map_check <<  endl;
        reset_offsets();
        if(map_check == 'R') {
            //a->hostRecCount = a->mRecCount;
            copyColumns(a, b->fil_value, segment, cnt);
            filter(b->fil_type,b->fil_value,b->fil_nums, b->fil_nums_f,a, b, segment);
        }
        else  {
            setPrm(a,b,map_check,segment);
        };
        if(segment == a->segCount-1)
            a->deAllocOnDevice();
        //cout << endl << "filter is finished " << b->mRecCount << " " << getFreeMem()  << endl;
    }
    //std::cout<< "filter time " <<  ( ( std::clock() - start1 ) / (double)CLOCKS_PER_SEC ) << " " << getFreeMem() << '\n';
}

void sort_right(CudaSet* right, unsigned int colInd2, string f2, queue<string> op_g, queue<string> op_sel,
                bool decimal_join, bool& str_join, size_t& rcount) {
		
	size_t cnt_r = 0;		
    right->hostRecCount = right->mRecCount;
   
    if (right->type[colInd2]  == 2) {
        str_join = 1;
        right->d_columns_int.push_back(thrust::device_vector<int_type>());
        for(unsigned int i = 0; i < right->segCount; i++) {
            right->add_hashed_strings(f2, i, right->d_columns_int.size()-1);
        };
        cnt_r = right->d_columns_int[right->d_columns_int.size()-1].size();
    };

    // need to allocate all right columns
    curr_segment = 10000000;
    string empty = "";

    if(right->not_compressed) {
        queue<string> op_alt1;
        op_alt1.push(f2);
        cnt_r = load_queue(op_alt1, right, str_join, empty, rcount, 0, right->segCount);
    }
    else {
        return; //assume already presorted data
    };

    if(str_join) {
        colInd2 = right->mColumnCount+1;
        right->type_index[colInd2] = right->d_columns_int.size()-1;
    };	

    //here we need to make sure that right column is ordered. If not then we order it and keep the permutation


    bool sorted;

    if(str_join || !decimal_join) {
        sorted = thrust::is_sorted(right->d_columns_int[right->type_index[colInd2]].begin(), right->d_columns_int[right->type_index[colInd2]].begin() + cnt_r);
    }
    else
        sorted = thrust::is_sorted(right->d_columns_float[right->type_index[colInd2]].begin(), right->d_columns_float[right->type_index[colInd2]].begin() + cnt_r);



    if(!sorted) {

        thrust::device_ptr<unsigned int> v = thrust::device_malloc<unsigned int>(cnt_r);
        thrust::sequence(v, v + cnt_r, 0, 1);

        unsigned int max_c	= max_char(right);
        unsigned int mm;
        if(max_c > 8)
            mm = max_c;
        else
            mm = 8;
        void* d;
        CUDA_SAFE_CALL(cudaMalloc((void **) &d, cnt_r*mm));


        if(str_join) {
            thrust::sort_by_key(right->d_columns_int[right->type_index[colInd2]].begin(), right->d_columns_int[right->type_index[colInd2]].begin() + cnt_r, v);
        }
        else {
            thrust::sort_by_key(right->d_columns_int[right->type_index[colInd2]].begin(), right->d_columns_int[right->type_index[colInd2]].begin() + cnt_r, v);
        };
		
		thrust::copy(right->d_columns_int[right->type_index[colInd2]].begin(), right->d_columns_int[right->type_index[colInd2]].begin() + cnt_r, right->h_columns_int[right->type_index[colInd2]].begin());
		right->deAllocColumnOnDevice(colInd2);

        unsigned int i;
        while(!op_sel.empty()) {
            if (right->columnNames.find(op_sel.front()) != right->columnNames.end()) {
                i = right->columnNames[op_sel.front()];

                if(i != colInd2) {

                    queue<string> op_alt1;
                    op_alt1.push(op_sel.front());
                    cnt_r = load_queue(op_alt1, right, str_join, empty, rcount, 0, right->segCount, 0, 0);

                    if(right->type[i] == 0) {
                        thrust::device_ptr<int_type> d_tmp((int_type*)d);
                        thrust::gather(v, v+cnt_r, right->d_columns_int[right->type_index[i]].begin(), d_tmp);
                        thrust::copy(d_tmp, d_tmp + cnt_r, right->h_columns_int[right->type_index[i]].begin());
                    }
                    else if(right->type[i] == 1) {
                        thrust::device_ptr<float_type> d_tmp((float_type*)d);
                        thrust::gather(v, v+cnt_r, right->d_columns_float[right->type_index[i]].begin(), d_tmp);
                        thrust::copy(d_tmp, d_tmp + cnt_r, right->h_columns_float[right->type_index[i]].begin());
                    }
                    else {
                        thrust::device_ptr<char> d_tmp((char*)d);
                        str_gather(thrust::raw_pointer_cast(v), cnt_r, (void*)right->d_columns_char[right->type_index[i]], (void*) thrust::raw_pointer_cast(d_tmp), right->char_size[right->type_index[i]]);
                        cudaMemcpy( (void*)right->h_columns_char[right->type_index[i]], (void*) thrust::raw_pointer_cast(d_tmp), cnt_r*right->char_size[right->type_index[i]], cudaMemcpyDeviceToDevice);
                    };
					right->deAllocColumnOnDevice(i);
                };
            };
            op_sel.pop();
        };
        thrust::device_free(v);
        cudaFree(d);
    }
    					
						
}						


size_t load_right(CudaSet* right, unsigned int colInd2, string f2, queue<string> op_g, queue<string> op_sel,
                        queue<string> op_alt, bool decimal_join, bool& str_join,
                        size_t& rcount, unsigned int start_seg, unsigned int end_seg, bool rsz) {

    size_t cnt_r = 0;
    //right->hostRecCount = right->mRecCount;
    //if join is on strings then add integer columns to left and right tables and modify colInd1 and colInd2

    if (right->type[colInd2]  == 2) {
        str_join = 1;
        right->d_columns_int.push_back(thrust::device_vector<int_type>());
        for(unsigned int i = start_seg; i < end_seg; i++) {
            right->add_hashed_strings(f2, i, right->d_columns_int.size()-1);
        };
        cnt_r = right->d_columns_int[right->d_columns_int.size()-1].size();
    };

    // need to allocate all right columns
    curr_segment = 10000000;
    string empty = "";

    if(right->not_compressed) {
        queue<string> op_alt1;
        op_alt1.push(f2);
        cnt_r = load_queue(op_alt1, right, str_join, empty, rcount, start_seg, end_seg, rsz, 1);
    }
    else {
        cnt_r = load_queue(op_alt, right, str_join, f2, rcount, start_seg, end_seg, rsz, 1);
    };

    if(str_join) {
        colInd2 = right->mColumnCount+1;
        right->type_index[colInd2] = right->d_columns_int.size()-1;
    };	

    if(right->not_compressed) {
        queue<string> op_alt1;
        while(!op_alt.empty()) {
            if(f2.compare(op_alt.front())) {
                if (right->columnNames.find(op_alt.front()) != right->columnNames.end()) {
                    op_alt1.push(op_alt.front());
                };
            };
            op_alt.pop();
        };
        cnt_r = load_queue(op_alt1, right, str_join, empty, rcount, start_seg, end_seg, 0, 0);
    };


    return cnt_r;
};

unsigned int calc_right_partition(CudaSet* left, CudaSet* right, queue<string> op_sel) {
	unsigned int tot_size = left->maxRecs*8;
	
	while(!op_sel.empty()) {
		if (right->columnNames.find(op_sel.front()) != right->columnNames.end()) {
					
		    if(right->type[right->columnNames[op_sel.front()]] <= 1) {
				tot_size = tot_size + right->maxRecs*8*right->segCount;
            }
            else {
				tot_size = tot_size + right->maxRecs*
									  right->char_size[right->type_index[right->columnNames[op_sel.front()]]]*
									  right->segCount;
			};
        };		
		op_sel.pop();			
	};		
	return right->segCount / ((tot_size/(getFreeMem() - 300000000)) + 1);
		
};