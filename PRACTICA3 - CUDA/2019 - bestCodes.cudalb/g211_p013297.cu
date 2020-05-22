// User: g211@157.88.125.152 
// ExecutionRequest[P:'clasico.cu',P:1,T:1,args:'',q:'cudalb'] 
// May 16 2019 13:42:41
#include "cputils.h" // Added by tablon
/*
 * Simplified simulation of fire extinguishing
 *
 * Computacion Paralela, Grado en Informatica (Universidad de Valladolid)
 * 2018/2019
 *
 * v1.4
 *
 * (c) 2019 Arturo Gonzalez Escribano
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <float.h>
#include <cputils.h>

#define RADIUS_TYPE_1		3
#define RADIUS_TYPE_2_3		9
#define THRESHOLD	0.1f
#define THREADS_PER_BLOCK 256

/* Structure to store data of an extinguishing team */
typedef struct {
	int x,y;
	int type;
	int target;
} Team;

/* Structure to store data of a fire focal point */
typedef struct {
	int x,y;
	int start;
	int heat;
	int active; // States: 0 Not yet activated; 1 Active; 2 Deactivated by a team
} FocalPoint;

/* Macro function to simplify accessing with two coordinates to a flattened array */
#define accessMat( arr, exp1, exp2 )	arr[ (exp1) * columns + (exp2) ]

/*
 * Function: Print usage line in stderr
 */
void show_usage( char *program_name ) {
	fprintf(stderr,"Usage: %s <config_file> | <command_line_args>\n", program_name );
	fprintf(stderr,"\t<config_file> ::= -f <file_name>\n");
	fprintf(stderr,"\t<command_line_args> ::= <rows> <columns> <maxIter> <numTeams> [ <teamX> <teamY> <teamType> ... ] <numFocalPoints> [ <focalX> <focalY> <focalStart> <focalTemperature> ... ]\n");
	fprintf(stderr,"\n");
}

#ifdef DEBUG
/* 
 * Function: Print the current state of the simulation 
 */
void print_status( int iteration, int rows, int columns, float *surface, int num_teams, Team *teams, int num_focal, FocalPoint *focal, float global_residual ) {
	/* 
	 * You don't need to optimize this function, it is only for pretty printing and debugging purposes.
	 * It is not compiled in the production versions of the program.
	 * Thus, it is never used when measuring times in the leaderboard
	 */
	int i,j;

	printf("Iteration: %d\n", iteration );
	printf("+");
	for( j=0; j<columns; j++ ) printf("---");
	printf("+\n");
	for( i=0; i<rows; i++ ) {
		printf("|");
		for( j=0; j<columns; j++ ) {
			char symbol;
			if ( accessMat( surface, i, j ) >= 1000 ) symbol = '*';
			else if ( accessMat( surface, i, j ) >= 100 ) symbol = '0' + (int)(accessMat( surface, i, j )/100);
			else if ( accessMat( surface, i, j ) >= 50 ) symbol = '+';
			else if ( accessMat( surface, i, j ) >= 25 ) symbol = '.';
			else symbol = '0';

			int t;
			int flag_team = 0;
			for( t=0; t<num_teams; t++ ) 
				if ( teams[t].x == i && teams[t].y == j ) { flag_team = 1; break; }
			if ( flag_team ) printf("[%c]", symbol );
			else {
				int f;
				int flag_focal = 0;
				for( f=0; f<num_focal; f++ ) 
					if ( focal[f].x == i && focal[f].y == j && focal[f].active == 1 ) { flag_focal = 1; break; }
				if ( flag_focal ) printf("(%c)", symbol );
				else printf(" %c ", symbol );
			}
		}
		printf("|\n");
	}
	printf("+");
	for( j=0; j<columns; j++ ) printf("---");
	printf("+\n");
	printf("Global residual: %f\n\n", global_residual);
}
#endif


__global__ void updateCositas (float *surf, float *copy, int rows, int columns) {
	int id=(threadIdx.x+blockIdx.x*blockDim.x)+(threadIdx.y+blockIdx.y*blockDim.y)*blockDim.x*gridDim.x;
	int i = id/columns;
	int j = id%columns;
	if(i > 0 && i < rows-1 && j > 0 && j < columns-1) {
		accessMat( surf, i, j ) = ( 
						accessMat( copy, i-1, j ) +
						accessMat( copy, i+1, j ) +
						accessMat( copy, i, j-1 ) +
						accessMat( copy, i, j+1 ) ) / 4;
		
	}

}

__global__ void updateFocal(float *surf, FocalPoint *focalCuda, int num_focal, int columns) {
	
	int id=(threadIdx.x+blockIdx.x*blockDim.x)+(threadIdx.y+blockIdx.y*blockDim.y)*blockDim.x*gridDim.x;
	if (id < num_focal){
		if ( focalCuda[id].active == 1 ){
			int x = focalCuda[id].x;
			int y = focalCuda[id].y;
			accessMat( surf, x, y ) = focalCuda[id].heat;
		}
	}
}


__global__ void reduce(float *surf, float *copy, float* resultados, int rows, int columns) {
	extern __shared__ float global[];
	// each thread loads one element from global to shared mem

	int id=(threadIdx.x+blockIdx.x*blockDim.x)+(threadIdx.y+blockIdx.y*blockDim.y)*blockDim.x*gridDim.x;
	int i = id/columns;
	int j = id%columns;
	int tid = threadIdx.x+threadIdx.y*blockDim.x;
	int bln = blockIdx.x+blockIdx.y*gridDim.x;
	if(id < columns*rows) {
		global[tid] = accessMat( surf, i, j ) - accessMat( copy, i, j ) ;
		if(global[tid] < 0) global[tid] = global[tid]*(-1.0f);
	}else{
		global[tid] = 0.0f;
	}
	
//		if(global[tid] !=0) printf("max %d no %d %f \n",blockDim.x*blockDim.y,tid,global[tid]);
	__syncthreads();

	// do reduction in shared mem
	for(int s=1; s < blockDim.x*blockDim.y; s *= 2) {
	//for(unsigned int s = (blockDim.x*blockDim.y)/2; s>32; s>>=1) {	
		
		if (tid%(2*s)==0) global[tid] = fmax(global[tid], global[tid + s]);
		//if (global[tid]!= 0) printf("%f si \n",global[tid]);
		
		__syncthreads();
	}
	// write result for this block to global mem
	if (tid == 0) resultados[bln] = global[0];
}

__device__ float atomicMaxf(float* vector, float valor)
{
    int *address_as_int =(int*)vector;
    int old = *address_as_int, assumed;
    while (valor > __int_as_float(old)) {
        assumed = old;
        old = atomicCAS(address_as_int, assumed,
                        __float_as_int(valor));
        }
    return __int_as_float(old);
}

/*
 * MAIN PROGRAM
 */
int main(int argc, char *argv[]) {
	int i,j,t;

	// Simulation data
	int rows, columns, max_iter;
	float *surface, *surfaceCopy;
	int num_teams, num_focal;
	Team *teams;
	FocalPoint *focal;

	/* 1. Read simulation arguments */
	/* 1.1. Check minimum number of arguments */
	if (argc<2) {
		fprintf(stderr,"-- Error in arguments: No arguments\n");
		show_usage( argv[0] );
		exit( EXIT_FAILURE );
	}

	int read_from_file = ! strcmp( argv[1], "-f" );
	/* 1.2. Read configuration from file */
	if ( read_from_file ) {
		/* 1.2.1. Open file */
		if (argc<3) {
			fprintf(stderr,"-- Error in arguments: file-name argument missing\n");
			show_usage( argv[0] );
			exit( EXIT_FAILURE );
		}
		FILE *args = cp_abrir_fichero( argv[2] );
		if ( args == NULL ) {
			fprintf(stderr,"-- Error in file: not found: %s\n", argv[1]);
			exit( EXIT_FAILURE );
		}	

		/* 1.2.2. Read surface and maximum number of iterations */
		int ok;
		ok = fscanf(args, "%d %d %d", &rows, &columns, &max_iter);
		if ( ok != 3 ) {
			fprintf(stderr,"-- Error in file: reading rows, columns, max_iter from file: %s\n", argv[1]);
			exit( EXIT_FAILURE );
		}

		surface = (float *)malloc( sizeof(float) * (size_t)rows * (size_t)columns );
		surfaceCopy = (float *)malloc( sizeof(float) * (size_t)rows * (size_t)columns );

		if ( surface == NULL || surfaceCopy == NULL ) {
			fprintf(stderr,"-- Error allocating: surface structures\n");
			exit( EXIT_FAILURE );
		}

		/* 1.2.3. Teams information */
		ok = fscanf(args, "%d", &num_teams );
		if ( ok != 1 ) {
			fprintf(stderr,"-- Error file, reading num_teams from file: %s\n", argv[1]);
			exit( EXIT_FAILURE );
		}
		teams = (Team *)malloc( sizeof(Team) * (size_t)num_teams );
		if ( teams == NULL ) {
			fprintf(stderr,"-- Error allocating: %d teams\n", num_teams );
			exit( EXIT_FAILURE );
		}
		for( i=0; i<num_teams; i++ ) {
			ok = fscanf(args, "%d %d %d", &teams[i].x, &teams[i].y, &teams[i].type);
			if ( ok != 3 ) {
				fprintf(stderr,"-- Error in file: reading team %d from file: %s\n", i, argv[1]);
				exit( EXIT_FAILURE );
			}
		}

		/* 1.2.4. Focal points information */
		ok = fscanf(args, "%d", &num_focal );
		if ( ok != 1 ) {
			fprintf(stderr,"-- Error in file: reading num_focal from file: %s\n", argv[1]);
			exit( EXIT_FAILURE );
		}
		focal = (FocalPoint *)malloc( sizeof(FocalPoint) * (size_t)num_focal );
		if ( focal == NULL ) {
			fprintf(stderr,"-- Error allocating: %d focal points\n", num_focal );
			exit( EXIT_FAILURE );
		}
		for( i=0; i<num_focal; i++ ) {
			ok = fscanf(args, "%d %d %d %d", &focal[i].x, &focal[i].y, &focal[i].start, &focal[i].heat);
			if ( ok != 4 ) {
				fprintf(stderr,"-- Error in file: reading focal point %d from file: %s\n", i, argv[1]);
				exit( EXIT_FAILURE );
			}
			focal[i].active = 0;
		}
	}
	/* 1.3. Read configuration from arguments */
	else {
		/* 1.3.1. Check minimum number of arguments */
		if (argc<6) {
			fprintf(stderr, "-- Error in arguments: not enough arguments when reading configuration from the command line\n");
			show_usage( argv[0] );
			exit( EXIT_FAILURE );
		}

		/* 1.3.2. Surface and maximum number of iterations */
		rows = atoi( argv[1] );
		columns = atoi( argv[2] );
		max_iter = atoi( argv[3] );

		surface = (float *)malloc( sizeof(float) * (size_t)rows * (size_t)columns );
		surfaceCopy = (float *)malloc( sizeof(float) * (size_t)rows * (size_t)columns );

		/* 1.3.3. Teams information */
		num_teams = atoi( argv[4] );
		teams = (Team *)malloc( sizeof(Team) * (size_t)num_teams );
		if ( teams == NULL ) {
			fprintf(stderr,"-- Error allocating: %d teams\n", num_teams );
			exit( EXIT_FAILURE );
		}
		if ( argc < num_teams*3 + 5 ) {
			fprintf(stderr,"-- Error in arguments: not enough arguments for %d teams\n", num_teams );
			exit( EXIT_FAILURE );
		}
		for( i=0; i<num_teams; i++ ) {
			teams[i].x = atoi( argv[5+i*3] );
			teams[i].y = atoi( argv[6+i*3] );
			teams[i].type = atoi( argv[7+i*3] );
		}

		/* 1.3.4. Focal points information */
		int focal_args = 5 + i*3;
		if ( argc < focal_args+1 ) {
			fprintf(stderr,"-- Error in arguments: not enough arguments for the number of focal points\n");
			show_usage( argv[0] );
			exit( EXIT_FAILURE );
		}
		num_focal = atoi( argv[focal_args] );
		focal = (FocalPoint *)malloc( sizeof(FocalPoint) * (size_t)num_focal );
		if ( teams == NULL ) {
			fprintf(stderr,"-- Error allocating: %d focal points\n", num_focal );
			exit( EXIT_FAILURE );
		}
		if ( argc < focal_args + 1 + num_focal*4 ) {
			fprintf(stderr,"-- Error in arguments: not enough arguments for %d focal points\n", num_focal );
			exit( EXIT_FAILURE );
		}
		for( i=0; i<num_focal; i++ ) {
			focal[i].x = atoi( argv[focal_args+i*4+1] );
			focal[i].y = atoi( argv[focal_args+i*4+2] );
			focal[i].start = atoi( argv[focal_args+i*4+3] );
			focal[i].heat = atoi( argv[focal_args+i*4+4] );
			focal[i].active = 0;
		}

		/* 1.3.5. Sanity check: No extra arguments at the end of line */
		if ( argc > focal_args+i*4+1 ) {
			fprintf(stderr,"-- Error in arguments: extra arguments at the end of the command line\n");
			show_usage( argv[0] );
			exit( EXIT_FAILURE );
		}
	}


#ifdef DEBUG
	/* 1.4. Print arguments */
	printf("Arguments, Rows: %d, Columns: %d, max_iter: %d\n", rows, columns, max_iter);
	printf("Arguments, Teams: %d, Focal points: %d\n", num_teams, num_focal );
	for( i=0; i<num_teams; i++ ) {
		printf("\tTeam %d, position (%d,%d), type: %d\n", i, teams[i].x, teams[i].y, teams[i].type );
	}
	for( i=0; i<num_focal; i++ ) {
		printf("\tFocal_point %d, position (%d,%d), start time: %d, temperature: %d\n", i, 
		focal[i].x,
		focal[i].y,
		focal[i].start,
		focal[i].heat );
	}
#endif // DEBUG

	/* 2. Select GPU and start global timer */
	cudaSetDevice(0);
	cudaDeviceSynchronize();
	double ttotal = cp_Wtime();

/*
 *
 * START HERE: DO NOT CHANGE THE CODE ABOVE THIS POINT
 *
 */

	/* 3. Initialize surface */
	/*for( i=0; i<rows; i++ ) {
		for( j=0; j<columns; j++ ) {
			accessMat( surface, i, j ) = 0.0;  // ESTO NO VA
			accessMat( surfaceCopy, i, j ) = 0.0; //------------------------
		}
	}*/
	/* 4. Simulation */

	int bloqueX = 8;
	int bloqueY = 16;
	int gridX, gridY;	
	
	if(rows%bloqueX==0) {
		gridX = rows/bloqueX;
	}else{
		gridX = rows/bloqueX+1;
	}
	if(columns%bloqueY==0) {
		gridY = columns/bloqueY;
	}else{
		gridY = columns/bloqueY+1;
	}
	

	dim3 sizeBloque(bloqueX,bloqueY);
	dim3 sizeGrid(gridX,gridY);




	int iter;
	int flag_stability = 0;
	int first_activation = 0;
	float *surfaceAux;//--------------------
	float *surfaceCuda;
	float *surfaceCopyCuda;
	float *resCuda;
	//float *surfaceAuxCuda;
	float *res;
	FocalPoint *focalCuda;
	res = (float *)malloc( sizeof(float) * (size_t)gridX * (size_t)gridY);
	cudaMalloc(&focalCuda, (sizeof(FocalPoint) * (size_t)num_focal));
        cudaMalloc(&resCuda,( sizeof(float) * (size_t)gridX * (size_t)gridY ));
        cudaMalloc(&surfaceCuda,( sizeof(float) * (size_t)rows * (size_t)columns ));
	cudaMalloc(&surfaceCopyCuda,( sizeof(float) * (size_t)rows * (size_t)columns ));
	



	for( iter=0; iter<max_iter && ! flag_stability; iter++ ) {

		/* 4.1. Activate focal points */
		int num_deactivated = 0;
		for( i=0; i<num_focal; i++ ) {
			if ( focal[i].start == iter ) {
				focal[i].active = 1;
				first_activation = 1;//---------------
			}
			// Count focal points already deactivated by a team
			if ( focal[i].active == 2 ) num_deactivated++;
		}
		if(first_activation == 0) continue;//-----------------------


		/* 4.2. Propagate heat (10 steps per each team movement) */
		float global_residual = 0.0f;
		int step;

		cudaMemcpy(surfaceCuda,surface,( sizeof(float) * (size_t)rows * (size_t)columns ),cudaMemcpyHostToDevice);
		cudaMemcpy(focalCuda,focal,(sizeof(FocalPoint) * (size_t)num_focal),cudaMemcpyHostToDevice);
		for( step=0; step<10; step++ )	{
			
			
			
			updateFocal<<<sizeGrid,sizeBloque>>>(surfaceCuda,focalCuda,num_focal,columns);

			surfaceAux=surfaceCuda;
			surfaceCuda=surfaceCopyCuda;   //-----------------------
			surfaceCopyCuda=surfaceAux;

			
			updateCositas<<<sizeGrid,sizeBloque>>>(surfaceCuda,surfaceCopyCuda,rows,columns);
			
			
			
			if(step == 0 && num_deactivated == num_focal) {
				int tamSize = sizeof(float) * (size_t)bloqueX * (size_t)bloqueY;
				reduce<<<sizeGrid,sizeBloque,tamSize>>>(surfaceCuda,surfaceCopyCuda,resCuda,rows,columns);
				cudaMemcpy(res,resCuda,( sizeof(float) * (size_t)gridX * (size_t)gridY),cudaMemcpyDeviceToHost);
				float aux = 0;
				for(i = 0; i<(gridX*gridY);i++) {
					aux = res[i];
					if(aux > global_residual) global_residual = aux;
				}

			}
			
		}
		cudaMemcpy(surface,surfaceCuda,( sizeof(float) * (size_t)rows * (size_t)columns ),cudaMemcpyDeviceToHost);

		
		/* If the global residual is lower than THRESHOLD, we have reached enough stability, stop simulation at the end of this iteration */
		if( num_deactivated == num_focal && global_residual < THRESHOLD ) flag_stability = 1;

		/* 4.3. Move teams */
	if(num_deactivated != num_focal) {
		for( t=0; t<num_teams; t++ ) {
			/* 4.3.1. Choose nearest focal point */
			float distance = FLT_MAX;
			int target = -1;
			for( j=0; j<num_focal; j++ ) {
				if ( focal[j].active != 1 ) continue; // Skip non-active focal points
				float dx = focal[j].x - teams[t].x;
				float dy = focal[j].y - teams[t].y;
				float local_distance = sqrtf( dx*dx + dy*dy );
				if ( local_distance < distance ) {
					distance = local_distance;
					target = j;
				}
			}
			/* 4.3.2. Annotate target for the next stage */
			teams[t].target = target;

			/* 4.3.3. No active focal point to choose, no movement */
			if ( target == -1 ) continue; 

			/* 4.3.4. Move in the focal point direction */
			if ( teams[t].type == 1 ) { 
				// Type 1: Can move in diagonal
				if ( focal[target].x < teams[t].x ) teams[t].x--;
				if ( focal[target].x > teams[t].x ) teams[t].x++;
				if ( focal[target].y < teams[t].y ) teams[t].y--;
				if ( focal[target].y > teams[t].y ) teams[t].y++;
			}
			else if ( teams[t].type == 2 ) { 
				// Type 2: First in horizontal direction, then in vertical direction
				if ( focal[target].y < teams[t].y ) teams[t].y--;
				else if ( focal[target].y > teams[t].y ) teams[t].y++;
				else if ( focal[target].x < teams[t].x ) teams[t].x--;
				else if ( focal[target].x > teams[t].x ) teams[t].x++;
			}
			else {
				// Type 3: First in vertical direction, then in horizontal direction
				if ( focal[target].x < teams[t].x ) teams[t].x--;
				else if ( focal[target].x > teams[t].x ) teams[t].x++;
				else if ( focal[target].y < teams[t].y ) teams[t].y--;
				else if ( focal[target].y > teams[t].y ) teams[t].y++;
			}
		}
	}
		/* 4.4. Team actions */
		for( t=0; t<num_teams; t++ ) {
			/* 4.4.1. Deactivate the target focal point when it is reached */
			int target = teams[t].target;
			if ( target != -1 && focal[target].x == teams[t].x && focal[target].y == teams[t].y 
				&& focal[target].active == 1 )
				focal[target].active = 2;

			/* 4.4.2. Reduce heat in a circle around the team */
			int radius;
			// Influence area of fixed radius depending on type
			if ( teams[t].type == 1 ) radius = RADIUS_TYPE_1;
			else radius = RADIUS_TYPE_2_3;
			for( i=teams[t].x-radius; i<=teams[t].x+radius; i++ ) {
				for( j=teams[t].y-radius; j<=teams[t].y+radius; j++ ) {
					if ( i<1 || i>=rows-1 || j<1 || j>=columns-1 ) continue; // Out of the heated surface
					float dx = teams[t].x - i;
					float dy = teams[t].y - j;
					float distance = sqrtf( dx*dx + dy*dy );
					if ( distance <= radius ) {
						accessMat( surface, i, j ) = accessMat( surface, i, j ) * ( 1 - 0.25 ); // Team efficiency factor
					}
				}
			}
		}

#ifdef DEBUG
		/* 4.5. DEBUG: Print the current state of the simulation at the end of each iteration */
		print_status( iter, rows, columns, surface, num_teams, teams, num_focal, focal, global_residual );
#endif // DEBUG
	}
	
/*
 *
 * STOP HERE: DO NOT CHANGE THE CODE BELOW THIS POINT
 *
 */

	/* 5. Stop global time */
	cudaDeviceSynchronize();
	ttotal = cp_Wtime() - ttotal;

	/* 6. Output for leaderboard */
	printf("\n");
	/* 6.1. Total computation time */
	printf("Time: %lf\n", ttotal );
	/* 6.2. Results: Number of iterations, position of teams, residual heat on the focal points */
	printf("Result: %d", iter);
	/*
	for (i=0; i<num_teams; i++)
		printf(" %d %d", teams[i].x, teams[i].y );
	*/
	for (i=0; i<num_focal; i++)
		printf(" %.6f", accessMat( surface, focal[i].x, focal[i].y ) );
	printf("\n");

	/* 7. Free resources */	
	free( teams );
	free( focal );
	free( surface );
	free( surfaceCopy );

	/* 8. End */
	return 0;
}
