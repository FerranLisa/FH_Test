// Baseline sequential, single-component JFIF. One MCU row per call lets
// the foreground service lwIP between strips. No heap or filesystem.
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <math.h>
#include "fh_jpeg.h"

static const uint8_t zig[64]={
 0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,
 27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,
 44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63};
static const uint8_t q[64]={
 5,3,3,5,7,12,15,18,4,4,4,6,8,17,18,17,4,4,5,7,12,17,21,17,
 4,5,7,9,15,26,24,19,5,7,11,17,20,33,31,23,7,11,17,19,24,31,34,28,
 15,19,23,26,31,36,36,30,22,28,29,29,34,30,31,30};
static float scale[64];
static void byte(FhJpeg *j,unsigned n){
    if(j->used<j->capacity) j->dst[j->used++]=(uint8_t)n;
    else j->failed=1;
}
static void word(FhJpeg *j,unsigned n){byte(j,n>>8);byte(j,n);}
static void bits(FhJpeg *j,unsigned value,unsigned count){
    j->bits=(j->bits<<count)|(value&((1u<<count)-1));
    j->count+=count;
    while(j->count>=8){
        j->count-=8;
        unsigned b=(j->bits>>j->count)&255;
        byte(j,b);
        if(b==255) byte(j,0);
    }
}
// Scaled eight-point forward DCT (Arai, Agui and Nakajima).
static void dct(float *p,int s){
    float a=p[0]+p[7*s],b=p[s]+p[6*s],c=p[2*s]+p[5*s],d=p[3*s]+p[4*s];
    float e=p[3*s]-p[4*s],f=p[2*s]-p[5*s],g=p[s]-p[6*s],h=p[0]-p[7*s];
    float even=(b-c+a-d)*0.707106781f;
    p[0]=a+d+b+c; p[4*s]=a+d-b-c;
    p[2*s]=a-d+even; p[6*s]=a-d-even;
    float t=e+f,u=f+g,v=g+h;
    float z=(t-v)*0.382683433f;
    float z2=t*0.541196100f+z,z4=v*1.306562965f+z;
    float z3=u*0.707106781f;
    p[s]=h+z3+z4; p[7*s]=h+z3-z4;
    p[5*s]=h-z3+z2; p[3*s]=h-z3-z2;
}
void fh_jpeg_begin(FhJpeg *j,uint8_t *out,size_t capacity){
    static const float a[]={1,1.387039845f,1.306562965f,1.175875602f,1,.785694958f,.541196100f,.275899379f};
    memset(j,0,sizeof *j);j->dst=out;j->capacity=capacity;
    for(int i=0;i<64;i++) scale[i]=1.f/(8*a[i/8]*a[i%8]*q[i]);
    word(j,0xffd8);
    word(j,0xffe0);word(j,16);
    const uint8_t jfif[]={74,70,73,70,0,1,1,0,0,1,0,1,0,0};
    for(unsigned i=0;i<sizeof jfif;i++) byte(j,jfif[i]);
    word(j,0xffdb);word(j,67);byte(j,0);
    for(int i=0;i<64;i++)byte(j,q[zig[i]]);
    word(j,0xffc0);word(j,11);byte(j,8);word(j,768);word(j,1024);
    byte(j,1);byte(j,1);byte(j,0x11);byte(j,0);
    // Short codes for common AC symbols. The remaining run/category
    // combinations use canonical 9-bit codes.
    word(j,0xffc4);word(j,2+17+12+17+162);
    byte(j,0);
    for(int i=1;i<=16;i++) byte(j,i==4?12:0);
    for(int i=0;i<12;i++)byte(j,i);
    byte(j,0x10);
    for(int i=1;i<=16;i++)byte(j,i==3?4:i==9?158:0);
    for(int i=0;i<4;i++)byte(j,i);
    byte(j,0xf0);
    for(int run=0;run<16;run++)for(int k=1;k<=10;k++)
        if(run || k>3)byte(j,(run<<4)|k);
    word(j,0xffda);word(j,8);byte(j,1);byte(j,1);byte(j,0);byte(j,0);byte(j,63);byte(j,0);
}
static unsigned category(int v){
    unsigned mag=(unsigned)(v<0?-v:v);
    return mag?32u-(unsigned)__builtin_clz(mag):0;
}
int fh_jpeg_strip(FhJpeg *j,const uint8_t *src){
    for(int col=0;col<1024;col+=8){
        float block[64];
        for(int y=0;y<8;y++){
            for(int x=0;x<8;x++)block[y*8+x]=(int)src[y*1024+col+x]-128;
            dct(block+y*8,1);
        }
        for(int x=0;x<8;x++)dct(block+x,8);
        int run=0;
        for(int i=0;i<64;i++){
            int n=zig[i];float f=block[n]*scale[n];
            int v=(int)(f+(f<0?-.5f:.5f));
            if(!i){
                int diff=v-j->dc;j->dc=v;
                unsigned k=category(diff);
                bits(j,k,4);bits(j,diff<0?diff-1:diff,k);
            }else if(!v){run++;}
            else{
                while(run>=16){bits(j,256,9);run-=16;}
                unsigned k=category(v);
                if(k>10){j->failed=1;return 0;}
                if(!run && k<=3)bits(j,k,3);
                else bits(j,257+run*10+k-4,9);
                bits(j,v<0?v-1:v,k);run=0;
            }
        }
        if(run)bits(j,0,3);
    }
    return !j->failed;
}
size_t fh_jpeg_end(FhJpeg *j){
    if(j->count)bits(j,255,8-j->count);
    word(j,0xffd9);
    return j->failed?0:j->used;
}
