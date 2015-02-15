###
#  Author: Cory M. Simon (CoryMSimon@gmail.com)
###
include("framework.jl")
include("forcefield.jl")
include("energyutils.jl")


function writegrid(adsorbate::String, structurename::String, forcefieldname::String; gridspacing=0.1, cutoff=12.5)
    """
    Compute the potential energy of an adsorbate molecule on a 3D grid of points superimposed on the unit cell of the structure.

    The grid is written to a file `structurename.cube`, in Gaussian cube format. The units of the energy are kJ/mol.

    :param: String adsorbate: the name of the adsorbate molecule, corresponding to the forcefield file
    """
    @printf("Constructing framework object for %s...\n", structurename)
    framework = constructframework(structurename)

    @printf("Constructing forcefield object for %s...\n", forcefieldname)
    forcefield = constructforcefield(forcefieldname, adsorbate, cutoff=cutoff)
    
    # get unit cell replication factors for periodic BCs
    rep_factors = get_replication_factors(framework.f_to_cartesian_mtrx, cutoff)
    @printf("Unit cell replication factors for LJ cutoff of %.2f A: %d by %d by %d\n", forcefield.cutoff, rep_factors[1], rep_factors[2], rep_factors[3])
    # how many grid points in each direction? 
    N_x = int(framework.a / gridspacing) + 1
    N_y = int(framework.b / gridspacing) + 1
    N_z = int(framework.c / gridspacing) + 1
    @printf("Grid is %d by %d by %d points, a total of %d grid points.\n", N_x, N_y, N_z, N_x*N_y*N_z)
    # fractional grid point spacing. Think of grid points as center of voxels.
    dx_f = 1.0 / (N_x - 1)
    dy_f = 1.0 / (N_y - 1)
    dz_f = 1.0 / (N_z - 1)
    @printf("Fractional grid spacing: dx_f = %f, dy_f = %f, dz_f = %f\n", dx_f, dy_f, dz_f)

    # get fractional coords of energy grid. 
    xf_grid = linspace(0.0, 1.0, N_x)
    yf_grid = linspace(0.0, 1.0, N_y)
    zf_grid = linspace(0.0, 1.0, N_z)
    
    # get grid point spacing in Cartesian space, just for kicks ^.^
    cartesian_spacing = framework.f_to_cartesian_mtrx * [xf_grid[2]-xf_grid[1], yf_grid[2]-yf_grid[1], zf_grid[2]-zf_grid[1]]
    @printf("Grid spacing: dx = %.2f, dy = %.2f, dz = %.2f\n", cartesian_spacing[1], cartesian_spacing[2], cartesian_spacing[3])

    # get array of framework atom positions and corresponding epsilons and sigmas for speed
    pos_array, epsilons, sigmas = _generate_pos_array_epsilons_sigmas(framework, forcefield)
    
    # open grid file
    if ! isdir(homedir() * "/PEGrid_output")
       mkdir(homedir() * "/PEGrid_output") 
    end
    gridfile = open(homedir() * "/PEGrid_output/" * framework.structurename * "_" * forcefield.adsorbate * ".cube", "w")

    # Format of .cube described here http://paulbourke.net/dataformats/cube/
    write(gridfile, "This is a grid file generated by PEviz\nLoop order: x, y, z\n")
    @printf(gridfile, "%d %f %f %f\n" , 0, 0.0, 0.0, 0.0)  # 0 atoms, then origin
    # TODO list atoms in the crystal structure
    @printf(gridfile, "%d %f %f %f\n" , N_x, framework.f_to_cartesian_mtrx[1,1] / (N_x - 1), 0.0, 0.0)  # N_x, vector along x-edge of voxel
    @printf(gridfile, "%d %f %f %f\n" , N_y, framework.f_to_cartesian_mtrx[1,2] / (N_y - 1), framework.f_to_cartesian_mtrx[2,2] / (N_y - 1), 0.0)  # N_y, vector along y-edge of voxel
    @printf(gridfile, "%d %f %f %f\n" , N_z, framework.f_to_cartesian_mtrx[1,3] / (N_z - 1), framework.f_to_cartesian_mtrx[2,3] / (N_z - 1), framework.f_to_cartesian_mtrx[3,3] / (N_z - 1))

    @printf("Writing grid...\n")
    # loop over [fractional] grid points, compute energies
    for i in 1:N_x  # loop over x_f-grid points
        # print progress
        if i % (int(N_x/10.0)) == 0
            @printf("\tPercent finished: %.1f\n", 100.0*i/N_x)
        end

        for j in 1:N_y  # loop over y_f-grid points
            for k in 1:N_z  # loop over z_f-grid points

                E = _E_vdw_at_point!(xf_grid[i], yf_grid[j], zf_grid[k], 
                                    pos_array, epsilons, sigmas, 
                                    framework,
                                    rep_factors, cutoff)
                
                # write energy at this point to grid file
                @printf(gridfile, "%e ", E * 8.314 / 1000.0)  # store in kJ/mol
                if (k % 6) == 0
                    @printf(gridfile, "\n")
                end

            end # end loop in z_f-grid points
            @printf(gridfile, "\n")
        end # end loop in y_f-grid points
    end # end loop in x_f-grid points
    close(gridfile)
    @printf("\tDone.\n")
end
