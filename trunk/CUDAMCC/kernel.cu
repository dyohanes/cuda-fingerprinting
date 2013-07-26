#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "ConvolutionHelper.h"
#include "BuildWorkingArea.h"
#include "FindMinutiae.h"
#include <string.h>

#define _USE_MATH_DEFINES
#include <math.h>

#define ceilMod(x, y) (x+y-1)/y

const int R = 70;
const int Ns = 16; // 8
const int Nd = 6;
const float SigmaD = 2* M_PI / 9;
const int BigSigma = 50; //
const float MinVC = 0.75; //
const int MinM = 2; // 
const float MinME = 0.6; //
const float SigmaTetta = M_PI / 2;  //
const int N = 10;
const int DictionaryCount = 360; // 720, 1440

__device__ const int cudaNs = 16; // 8
__device__ const int cudaNd = 6;
__device__ const float cudaSigmaS = 28 / 3;
__device__ const float cudaSigmaD = 2* M_PI / 9;
__device__ const float cudaMuPsi = 0.001;
__device__ const int cudaBigSigma = 50; //
__device__ const float cudaMinVC = 0.75; //
__device__ const int cudaMinM = 2; //
__device__ const float cudaMinME = 0.6; //
__device__ const float cudaSigmaTetta = M_PI / 2;  //
__device__ const int cudaN = 10;
__device__ const int cudaDictionaryCount = 360; // 720, 1440

__host__ __device__ struct Cell
{
	Minutiae minutia;
	int value;
	int mask;
};

__device__ int Psi(float v)
{
	if (v >= cudaMuPsi) 
	{
		return 1;
	}

	return 0;
}

__device__ float GetIntegralParameterIndex(float param, CUDAArray<float> integralParameters)
{
	for (int i = 0; i < cudaDictionaryCount; i++)
	{
		if (abs(integralParameters.At(0, i) - param) <= M_PI / cudaDictionaryCount)
		{
			return i;
		}
	}

	// never use
	return 0;
}

__device__ float GetAngleFromLevel(int k, float deltaD)
{
	return M_PI + (k - 1 / 2) * deltaD;
}

__device__ float NormalizeAngle(float angle)
{
	if (angle < -M_PI)
	{
		return 2 * M_PI + angle;
	}

	if (angle < M_PI)
	{
		return angle;
	}

	return -2 * M_PI + angle;
}

__device__ float GetDirectionalContribution(float mAngle, float mtAngle, int k, CUDAArray<float> integralParameters, CUDAArray<float> integralValues, float deltaD)
{
	float angleFromLevel = NormalizeAngle(GetAngleFromLevel(k, deltaD));
	float differenceAngles = NormalizeAngle(mAngle - mtAngle);
	float param = NormalizeAngle(angleFromLevel - differenceAngles);
	int indexOfResult = GetIntegralParameterIndex(param, integralParameters);

	return integralValues.At(0, indexOfResult);
}

__device__ float GetDistance(int x1, int y1, int x2, int y2)
{
	return sqrt((float)((x1 - x2) * (x1 - x2) + (y1 - y2) * (y1 - y2)));
}

__device__ float GetSpatialContribution(Minutiae m, int currentCellX, int currentCellY)
{
	float distance = GetDistance(m.x, m.y, currentCellX, currentCellY);

	float commonDenom = cudaSigmaS * cudaSigmaS * 2;
	float denominator = cudaSigmaS * sqrt(M_PI * 2);
	float result = exp(-(distance * distance) / commonDenom) / denominator;

	return result;
}

__device__ bool IsEqualMinutiae(Minutiae m1, Minutiae m2)
{
	return m1.x == m2.x && m1.y == m2.y && m1.angle == m2.angle;
}

__device__ void GetCoordinatesInFingerprint(int& pointX, int& pointY, Minutiae m, int i, int j, float deltaS)
{
	float halfNs = (1 + cudaNs) / 2;
	float sinTetta = sin(m.angle);
	float cosTetta = cos(m.angle);
	float iDelta = cosTetta * (i - halfNs) + sinTetta * (j - halfNs);
	float jDelta = -sinTetta * (i - halfNs) + cosTetta * (j - halfNs);
    
	pointX = (int)(m.x + deltaS * iDelta);
	pointY = (int)(m.y + deltaS * jDelta);
}

__device__ int CalculateMaskValue(Minutiae m, int i, int j, int rows, int columns, CUDAArray<int> workingArea, float deltaS)
{
	int pointX = 0; 
	int pointY = 0; 
	
	GetCoordinatesInFingerprint(pointX, pointY, m, i, j, deltaS);
            
	if (pointX < 0 || pointX >= rows ||
		pointY < 0 || pointY >= columns)
	{
		return 0;
	}
            
	return ((GetDistance(m.x, m.y, pointX, pointY) <= R) && (workingArea.At(pointY, pointX) == 1))
		? 1
		: 0;
}

__device__ void GetallNeighbours(Minutiae* minutiae, CUDAArray<int> numOfNeighbours, int numOfMinutiae)
{
	int sum = 0;
	int current = blockIdx.x * blockDim.x * blockDim.y + threadIdx.y * blockDim.x + threadIdx.x;
	for (int i = 0; i < numOfMinutiae; i++)
	{
		if(GetDistance(minutiae[i].x,minutiae[i].y, minutiae[current].x,minutiae[current].y)<=(R+3*cudaSigmaS)
			&& (minutiae[i].x!=minutiae[current].x || minutiae[i].y!=minutiae[current].y))
		{
			sum ++;
		}
	}
	numOfNeighbours.SetAt(0, current, sum);
}

__global__ void check(CUDAArray<int> result, CUDAArray<int> numOfValidMask, Minutiae* minutiae, CUDAArray<int> numOfNeighbours, int numOfMinutiae)
{
	GetallNeighbours(minutiae, numOfNeighbours,numOfMinutiae);
	int current = blockIdx.x * blockDim.x * blockDim.y + threadIdx.y * blockDim.x + threadIdx.x;
	int res = (numOfValidMask.At(0, current) > cudaMinVC) && (numOfNeighbours.At(0, current) > cudaMinM);
	result.SetAt(0,current, res);
}

__global__ void cudaMCC (CUDAArray<Minutiae> minutiae, int minutiaeCount, CUDAArray<float> integralParameters, 
	CUDAArray<float> integralValues, int rows, int columns, CUDAArray<int> workingArea, 
	float deltaS, float deltaD, CUDAArray<Cell> arr, CUDAArray<int> numOfValidMask)
{
	Cell result;
	int row = defaultRow(); // J  < ~80
	int column = defaultColumn(); // I  < 1536 = 16*16*6
	
	int index = row;
	int i = column % ((cudaNs - 1) * (cudaNd - 1));
	int j = (column - i*((cudaNs - 1) * (cudaNd - 1))) % (cudaNd - 1);
	int k = (column - i*((cudaNs - 1) * (cudaNd - 1))) - j * (cudaNd - 1);

	int coordinateX = 0; 
	int coordinateY = 0; 
	float psiParameter = 0;
	float spatialContribution = 0;
	float directionalContribution = 0;

	GetCoordinatesInFingerprint(coordinateX, coordinateY, minutiae.At(0, index), i, j, deltaS);

	if (coordinateX < 0 || coordinateX >= rows ||
		coordinateY < 0 || coordinateY >= columns)
	{
		result.minutia = minutiae.At(0, index);
		result.mask = 0;
		result.value = 0;
		arr.SetAt(row, column, result);

		return;
	}

	for (int i = 0; i < minutiaeCount; i++)
	{
		if (!IsEqualMinutiae(minutiae.At(0, i), minutiae.At(0, index)) && 
			GetDistance((minutiae.At(0, i)).x, (minutiae.At(0, i)).y, coordinateX, coordinateY) <= 3 * cudaSigmaS)
		{
			spatialContribution = GetSpatialContribution(minutiae.At(0, i), coordinateX, coordinateY);
			directionalContribution = GetDirectionalContribution((minutiae.At(0, index)).angle, (minutiae.At(0, i)).angle, k, integralParameters, integralValues, deltaD);
			psiParameter = psiParameter + spatialContribution * directionalContribution;
		}
	}

	int psiValue = Psi(psiParameter); 
	int maskValue = CalculateMaskValue(minutiae.At(0, index), i, j, rows, columns, workingArea, deltaS);
	if(maskValue > 0)
	{
		numOfValidMask.SetAt(0, column, numOfValidMask.At(0,column)+1);
	}
	result.minutia = minutiae.At(0, index);
	result.mask = maskValue;
	result.value = psiValue;
	arr.SetAt(row, column, result);

	// check

	//allNeighbours.AddRange(neighbourMinutiae);
	//allNeighbours = MinutiaListDistinct(allNeighbours);
	
	//if (allNeighbours.Count < Constants.MinM && !IsValidMask())
	//{
	//	continue;
	//}

}

void MCCMethod(Cell* result, int* resultOfCheck, Minutiae* minutiae, int minutiaeCount, int rows, int columns, int* workingArea,
	float deltaS, float deltaD, CUDAArray<float> cudaIntegralParameters, CUDAArray<float> cudaIntegralValues)
{
		CUDAArray<Minutiae> cudaMinutiae = CUDAArray<Minutiae>(minutiae, minutiaeCount, 1);
		CUDAArray<int> cudaWorkingArea = CUDAArray<int>(workingArea, columns, rows);
		CUDAArray<Cell> cudaResult = CUDAArray<Cell>(result, Ns * Ns * Nd, minutiaeCount); // result
		
		int* numOfValid = (int*)malloc(sizeof(int)*minutiaeCount);
		memset (numOfValid, 0, minutiaeCount);
		CUDAArray<int> numOfValidMask = CUDAArray<int>(numOfValid, 1,minutiaeCount);
		CUDAArray<int> cudaResultOfCheck = CUDAArray<int>(numOfValid, 1,minutiaeCount);
		CUDAArray<int> numOfNeighbours = CUDAArray<int>(numOfValid, 1,minutiaeCount);

		dim3 blockSize = dim3(defaultThreadCount,defaultThreadCount);
		dim3 gridSize = dim3(ceilMod(Ns * Ns * Nd, defaultThreadCount), ceilMod(minutiaeCount, defaultThreadCount));
 
		cudaMCC<<<gridSize,blockSize>>>(cudaMinutiae, minutiaeCount, cudaIntegralParameters, cudaIntegralValues, 
		rows, columns, cudaWorkingArea, deltaS, deltaD, cudaResult, numOfValidMask);
 
		// call checking for each minutiae
		gridSize = dim3(ceilMod(minutiaeCount, defaultThreadCount));
		check<<<gridSize,blockSize>>>(cudaResultOfCheck, numOfValidMask, minutiae, numOfNeighbours, minutiaeCount);

		cudaResult.GetData(result);
		cudaResultOfCheck.GetData(resultOfCheck);

		cudaMinutiae.Dispose();
		cudaWorkingArea.Dispose();
		cudaResult.Dispose();
}

__global__ void cudaMakeTableOfIntegrals(CUDAArray<float> integralParameters, CUDAArray<float> integralValues, float factor, float h, float deltaD)
{
	int column = blockIdx.x * blockDim.x * blockDim.y + threadIdx.y * blockDim.x + threadIdx.x;
	float a = integralParameters.At(0, column) - deltaD / 2;
	float integrand = 0;
	float result = 0;

	for (int i = 0; i < cudaN; i++)
	{
		integrand = a + ((2 * i + 1) * h) / 2;
		integrand = exp((-integrand * integrand) / (2 * cudaSigmaD * cudaSigmaD));
		result += h * integrand;    
	}
	
	integralValues.SetAt(0, column, result * factor);
}

float* InitializeIntegralParameters()
{
	float* integralParameters = (float*)malloc(DictionaryCount*sizeof(float));
	float key = -M_PI;
	float step = 2 * M_PI / DictionaryCount;
	for (int i = 0; i < DictionaryCount; i++)
	{
		integralParameters[i] = key;
		key += step;
	}

	return integralParameters;
}

void Init(float& deltaS, float& deltaD, CUDAArray<float> cudaIntegralParameters, CUDAArray<float> cudaIntegralValues)
{
	cudaError_t cudaStatus = cudaSetDevice(0);

	deltaS = 2 * R / Ns;
	deltaD = 2 * M_PI / Nd;
	float* integralParameters = InitializeIntegralParameters();
	 
	cudaIntegralParameters = CUDAArray<float>(integralParameters, DictionaryCount, 1);
	cudaIntegralValues = CUDAArray<float>(DictionaryCount, 1);
	cudaStatus = cudaGetLastError();
	if (cudaStatus != cudaSuccess) 
	{
		printf("cudaIntegralValues = CUDAArray<float>(DictionaryCount, 1); - ERROR!!!\n");
	}

	float factor = 1 / (SigmaD * sqrt(2 * M_PI));
	float h = deltaD / N;
	dim3 blockSize = dim3(defaultThreadCount,defaultThreadCount);
	dim3 gridSize = dim3(ceilMod(DictionaryCount, defaultThreadCount));
		 
	cudaMakeTableOfIntegrals<<<gridSize,blockSize>>>(cudaIntegralParameters, cudaIntegralValues, factor, h, deltaD);
	cudaStatus = cudaGetLastError();
	if (cudaStatus != cudaSuccess) 
	{
		printf("cudaMakeTableOfIntegrals - ERROR!!!\n");
	}
}

void LoadImage(int* sourceInt, const char* name, bool sourceIsFloat = false)
{
	FILE* f = fopen(name,"rb");
			
	int width;
	int height;
	
	fread(&width,sizeof(int),1,f);			
	fread(&height,sizeof(int),1,f);
	
	if(!sourceIsFloat)
	{
		int* ar = (int*)malloc(sizeof(int)*width*height);
		fread(ar,sizeof(int),width*height,f);
		for(int i=0;i<width*height;i++)
		{
			sourceInt[i]=ar[i];
		}
		
		free(ar);
	}
	else
	{
		fread(sourceInt,sizeof(int),width*height,f);
	}
	
	fclose(f);
}

void main()
{
	int width = 256;
	int height = 364;

	int* sourceInt = (int*)malloc(width*height*sizeof(int));
	LoadImage(sourceInt, "C:\\Users\\Tanya\\Documents\\Studies\\SummerSch0ol2013\\SVN\\CUDAFingerprinting.TemplateBuilding.Minutiae.BinarizationThinking.Tests\\Resources\\104_61globalBinarization150Thinned.phg");

	Minutiae* minutiae = (Minutiae*)malloc(width*height*sizeof(Minutiae));
	int* minutiaeCounter = (int*)malloc(sizeof(int));
	int* minutiaeAsIntArr = (int*)malloc(minutiaeCounter[0] * 2 * sizeof(int));
	int* workingArea = (int*)malloc(width*height*sizeof(int));

	FindBigMinutiaeCUDA(sourceInt, width, height, minutiae, minutiaeCounter, R);

	for (int i = 0; i < minutiaeCounter[0] * 2; i++)
	{
		if (i % 2 == 0)
		{
			minutiaeAsIntArr[i] = minutiae[i / 2].x;
		}
		else
		{
			minutiaeAsIntArr[i] = minutiae[i / 2].y;
		}
	}

	BuildWorkingArea(workingArea, height, width, R, minutiaeAsIntArr, minutiaeCounter[0]);
	
	Cell* result = (Cell*)malloc(Ns * Ns * Nd * minutiaeCounter[0] * sizeof(Cell)); 
	int* resultOfCheck = (int*)malloc(sizeof(int)* minutiaeCounter[0]);
	float deltaS;
	float deltaD;
	CUDAArray<float> cudaIntegralParameters;
	CUDAArray<float> cudaIntegralValues;
	
	Init(deltaS, deltaD, cudaIntegralParameters, cudaIntegralValues);
	MCCMethod(result, resultOfCheck, minutiae, minutiaeCounter[0], height, width, workingArea, 
		deltaS, deltaD, cudaIntegralParameters, cudaIntegralValues);
	
	
	cudaIntegralParameters.Dispose();
	cudaIntegralValues.Dispose();
	free(sourceInt);
	cudaFree(minutiae);
	cudaFree(minutiaeCounter);
	cudaFree(minutiaeAsIntArr);
	cudaFree(workingArea);
}